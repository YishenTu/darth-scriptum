import Darwin
import Foundation

enum DurableFileIO {
    static func createDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = url.standardizedFileURL
        var missingDirectories: [URL] = []
        var cursor = directoryURL

        while !fileManager.fileExists(atPath: cursor.path) {
            missingDirectories.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw CocoaError(.fileNoSuchFile)
            }
            cursor = parent
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        for createdDirectory in missingDirectories.reversed() {
            try synchronizeDirectory(createdDirectory)
            try synchronizeDirectory(
                createdDirectory.deletingLastPathComponent()
            )
        }
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try createDirectory(at: directoryURL)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw posixError()
        }

        var descriptorIsOpen = true
        var shouldRemoveTemporaryFile = true
        defer {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                _ = temporaryURL.path.withCString { Darwin.unlink($0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else {
                    throw posixError()
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError()
        }
        guard Darwin.close(descriptor) == 0 else {
            throw posixError()
        }
        descriptorIsOpen = false

        let renameResult = temporaryURL.path.withCString { temporaryPath in
            url.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixError()
        }
        shouldRemoveTemporaryFile = false
        try synchronizeDirectory(directoryURL)
    }

    static func synchronizeDirectoryEntry(for directoryURL: URL) throws {
        try synchronizeDirectory(directoryURL)
        try synchronizeDirectory(directoryURL.deletingLastPathComponent())
    }

    /// Renames one recovery artifact within its owning filesystem and makes
    /// the directory entry durable before returning. Recovery transactions use
    /// this instead of a best-effort FileManager move so interrupted deletes
    /// can be deterministically replayed from their journal.
    static func moveAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw posixError()
        }
        try synchronizeDirectory(sourceURL.deletingLastPathComponent())
        if sourceURL.deletingLastPathComponent().standardizedFileURL
            != destinationURL.deletingLastPathComponent().standardizedFileURL {
            try synchronizeDirectory(destinationURL.deletingLastPathComponent())
        }
    }

    /// Removes a file and synchronizes its parent directory. Callers must
    /// first make recovery deletion recoverable through a durable journal.
    static func removeDurably(at url: URL) throws {
        let result = url.path.withCString { Darwin.unlink($0) }
        guard result == 0 else {
            throw posixError()
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError()
        }
    }

    static func resourceIdentifier(for url: URL) throws -> String {
        var status = Darwin.stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &status)
        }
        guard result == 0 else {
            throw posixError()
        }
        return "\(status.st_dev):\(status.st_ino)"
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
