import Darwin
import Dispatch
import Foundation

final class DirectoryFileMonitor: @unchecked Sendable {
    private let targetURL: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let onDescriptorClosed: (@Sendable (Bool) -> Void)?
    private let startupHook: (@Sendable () throws -> Void)?
    private var directoryDescriptor: Int32 = -1
    private var fileDescriptor: Int32 = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    init(
        targetURL: URL,
        onChange: @escaping @Sendable () -> Void,
        onDescriptorClosed: (@Sendable (Bool) -> Void)? = nil,
        startupHook: (@Sendable () throws -> Void)? = nil
    ) {
        self.targetURL = targetURL
        self.onChange = onChange
        self.onDescriptorClosed = onDescriptorClosed
        self.startupHook = startupHook
        queue = DispatchQueue(
            label: "com.yishentu.DarthScriptum.directory-monitor.\(UUID().uuidString)",
            qos: .utility
        )
    }

    func start() throws {
        guard directorySource == nil, fileSource == nil else { return }
        try startupHook?()

        directoryDescriptor = open(
            targetURL.deletingLastPathComponent().path,
            O_EVTONLY | O_NONBLOCK | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        fileDescriptor = open(
            targetURL.path,
            O_EVTONLY | O_NONBLOCK | O_CLOEXEC
        )
        if fileDescriptor < 0, errno != ENOENT {
            let fileError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = close(directoryDescriptor)
            directoryDescriptor = -1
            throw fileError
        }
        if fileDescriptor >= 0 {
            var metadata = stat()
            guard fstat(fileDescriptor, &metadata) == 0 else {
                let fileError = POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
                _ = close(fileDescriptor)
                _ = close(directoryDescriptor)
                fileDescriptor = -1
                directoryDescriptor = -1
                throw fileError
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                _ = close(fileDescriptor)
                _ = close(directoryDescriptor)
                fileDescriptor = -1
                directoryDescriptor = -1
                throw TextFileCodec.CodecError.unsupportedFileType
            }
        }

        let directorySource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        directorySource.setEventHandler { [weak self] in
            self?.onChange()
        }
        let monitoredDirectoryDescriptor = directoryDescriptor
        let onDescriptorClosed = self.onDescriptorClosed
        directorySource.setCancelHandler {
            onDescriptorClosed?(close(monitoredDirectoryDescriptor) == 0)
        }
        self.directorySource = directorySource

        if fileDescriptor >= 0 {
            let fileSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .delete, .rename, .extend, .revoke],
                queue: queue
            )
            fileSource.setEventHandler { [weak self] in
                self?.onChange()
            }
            let monitoredFileDescriptor = fileDescriptor
            fileSource.setCancelHandler {
                onDescriptorClosed?(close(monitoredFileDescriptor) == 0)
            }
            self.fileSource = fileSource
            fileSource.resume()
        }

        directorySource.resume()
    }

    func cancel() {
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = nil
        directorySource = nil
        fileDescriptor = -1
        directoryDescriptor = -1
    }

    deinit {
        cancel()
    }
}
