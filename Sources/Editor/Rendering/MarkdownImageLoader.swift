import CoreGraphics
import Darwin
import Foundation
import ImageIO

struct MarkdownImageLoadRequest: Sendable, Equatable {
    let rootURL: URL
    let targetURL: URL
    fileprivate let directoryAuthority: MarkdownImageDirectoryAuthority?
    fileprivate let relativePathComponents: [String]?

    init(rootURL: URL, targetURL: URL) {
        self.rootURL = rootURL
        self.targetURL = targetURL
        directoryAuthority = nil
        relativePathComponents = nil
    }

    fileprivate init(
        rootURL: URL,
        targetURL: URL,
        directoryAuthority: MarkdownImageDirectoryAuthority,
        relativePathComponents: [String]
    ) {
        self.rootURL = rootURL
        self.targetURL = targetURL
        self.directoryAuthority = directoryAuthority
        self.relativePathComponents = relativePathComponents
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootURL == rhs.rootURL
            && lhs.targetURL == rhs.targetURL
            && lhs.relativePathComponents == rhs.relativePathComponents
            && lhs.directoryAuthority?.identity
                == rhs.directoryAuthority?.identity
    }
}

private struct MarkdownImageDirectoryIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
}

private final class MarkdownImageDirectoryAuthority: @unchecked Sendable {
    let descriptor: Int32
    let identity: MarkdownImageDirectoryIdentity

    init?(directoryURL: URL) {
        let descriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR
        else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        identity = MarkdownImageDirectoryIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    func duplicatedDescriptor() -> Int32? {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { return nil }
        guard fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else {
            close(duplicate)
            return nil
        }
        return duplicate
    }

    deinit {
        close(descriptor)
    }
}

enum MarkdownImageSecureFileAccess {
    static func openRegularFile(
        for request: MarkdownImageLoadRequest,
        flags: Int32
    ) -> Int32? {
        guard
            let authority = request.directoryAuthority,
            let components = request.relativePathComponents,
            let finalComponent = components.last,
            !finalComponent.isEmpty,
            let rootDescriptor = authority.duplicatedDescriptor()
        else {
            return nil
        }

        var directoryDescriptor = rootDescriptor
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            close(directoryDescriptor)
            guard nextDescriptor >= 0 else { return nil }
            directoryDescriptor = nextDescriptor
        }

        let fileDescriptor = finalComponent.withCString {
            openat(
                directoryDescriptor,
                $0,
                flags | O_CLOEXEC | O_NOFOLLOW
            )
        }
        close(directoryDescriptor)
        guard fileDescriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG
        else {
            close(fileDescriptor)
            return nil
        }
        return fileDescriptor
    }
}

struct MarkdownDecodedImage: @unchecked Sendable {
    let image: CGImage
    let decodedCost: Int
}

protocol MarkdownImageLoading: Sendable {
    func load(_ request: MarkdownImageLoadRequest) -> MarkdownDecodedImage?

    func authorizedRequest(
        for request: MarkdownImageLoadRequest
    ) -> MarkdownImageLoadRequest?

    func load(
        _ request: MarkdownImageLoadRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) -> MarkdownDecodedImage?
}

extension MarkdownImageLoading {
    func authorizedRequest(
        for request: MarkdownImageLoadRequest
    ) -> MarkdownImageLoadRequest? {
        request
    }

    func load(
        _ request: MarkdownImageLoadRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) -> MarkdownDecodedImage? {
        guard !cancellationCheck() else { return nil }
        let image = load(request)
        return cancellationCheck() ? nil : image
    }
}

struct MarkdownImageLoader: MarkdownImageLoading, Sendable {
    static let maximumEncodedImageBytes = 32 * 1_024 * 1_024
    static let maximumDecodedImageCost = 32 * 1_024 * 1_024
    static let maximumImageFrameCount = 256
    private static let readChunkSize = 64 * 1_024
    private let beforeSecureOpen: (@Sendable () -> Void)?

    init(beforeSecureOpen: (@Sendable () -> Void)? = nil) {
        self.beforeSecureOpen = beforeSecureOpen
    }

    nonisolated func load(
        _ request: MarkdownImageLoadRequest
    ) -> MarkdownDecodedImage? {
        load(request, cancellationCheck: { false })
    }

    nonisolated func authorizedRequest(
        for request: MarkdownImageLoadRequest
    ) -> MarkdownImageLoadRequest? {
        if request.directoryAuthority != nil,
            request.relativePathComponents?.isEmpty == false
        {
            return request
        }
        guard
            let lexicalPathComponents = descendantPathComponents(
                of: request.targetURL.standardizedFileURL,
                under: request.rootURL.standardizedFileURL
            ),
            let rootURL = canonicalDirectoryURL(request.rootURL),
            let targetURL = canonicalFileURL(request.targetURL),
            let canonicalPathComponents = descendantPathComponents(
                of: targetURL,
                under: rootURL
            ),
            lexicalPathComponents == canonicalPathComponents,
            let directoryAuthority = MarkdownImageDirectoryAuthority(
                directoryURL: rootURL
            )
        else {
            return nil
        }
        return MarkdownImageLoadRequest(
            rootURL: rootURL,
            targetURL: targetURL,
            directoryAuthority: directoryAuthority,
            relativePathComponents: canonicalPathComponents
        )
    }

    nonisolated func load(
        _ request: MarkdownImageLoadRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) -> MarkdownDecodedImage? {
        guard
            !cancellationCheck(),
            let request = authorizedRequest(for: request),
            !cancellationCheck()
        else {
            return nil
        }
        beforeSecureOpen?()
        guard
            !cancellationCheck(),
            let data = boundedFileData(
                for: request,
                cancellationCheck: cancellationCheck
            ),
            !cancellationCheck(),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let decodedSourceCost = decodedCost(
                of: source,
                cancellationCheck: cancellationCheck
            ),
            decodedSourceCost > 0,
            !cancellationCheck(),
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            ),
            let decodedCost = Self.decodedCost(of: image),
            !cancellationCheck()
        else {
            return nil
        }
        return MarkdownDecodedImage(image: image, decodedCost: decodedCost)
    }

    static func decodedCost(
        width: Int,
        height: Int,
        bitsPerComponent: Int = 8
    ) -> Int? {
        guard width > 0, height > 0, bitsPerComponent > 0 else {
            return nil
        }
        let storageBitsPerComponent = max(bitsPerComponent, 8)
        let (bitsPerPixel, bitsOverflow) =
            storageBitsPerComponent.multipliedReportingOverflow(by: 4)
        guard !bitsOverflow else { return nil }
        let (roundedBitsPerPixel, roundingOverflow) =
            bitsPerPixel.addingReportingOverflow(7)
        guard !roundingOverflow else { return nil }
        let bytesPerPixel = roundedBitsPerPixel / 8
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        guard !pixelOverflow else { return nil }
        let (cost, byteOverflow) = pixelCount.multipliedReportingOverflow(
            by: bytesPerPixel
        )
        guard !byteOverflow, cost <= maximumDecodedImageCost else {
            return nil
        }
        return cost
    }

    static func decodedCost(of image: CGImage) -> Int? {
        guard image.bytesPerRow > 0, image.height > 0 else { return nil }
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        guard !overflow, cost <= maximumDecodedImageCost else { return nil }
        return cost
    }

    private func canonicalDirectoryURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let canonicalURL = url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard
            let values = try? canonicalURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ),
            values.isDirectory == true
        else {
            return nil
        }
        return canonicalURL
    }

    private func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func descendantPathComponents(
        of url: URL,
        under rootURL: URL
    ) -> [String]? {
        let components = url.pathComponents
        let rootComponents = rootURL.pathComponents
        guard components.count > rootComponents.count,
            zip(components, rootComponents).allSatisfy(==)
        else {
            return nil
        }
        let relativeComponents = Array(components.dropFirst(rootComponents.count))
        guard
            relativeComponents.allSatisfy({ component in
                !component.isEmpty && component != "." && component != ".."
            })
        else {
            return nil
        }
        return relativeComponents
    }

    private func boundedFileData(
        for request: MarkdownImageLoadRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) -> Data? {
        guard !cancellationCheck() else { return nil }
        guard
            let descriptor = MarkdownImageSecureFileAccess.openRegularFile(
                for: request,
                flags: O_RDONLY | O_NONBLOCK
            )
        else {
            return nil
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { try? handle.close() }

        var metadata = stat()
        guard !cancellationCheck(),
            fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size >= 0,
            metadata.st_size <= Self.maximumEncodedImageBytes
        else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        do {
            while data.count <= Self.maximumEncodedImageBytes {
                guard !cancellationCheck() else { return nil }
                let remainingAllowance =
                    Self.maximumEncodedImageBytes - data.count + 1
                let count = min(Self.readChunkSize, remainingAllowance)
                guard let chunk = try handle.read(upToCount: count),
                    !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
                guard !cancellationCheck() else { return nil }
            }
        } catch {
            return nil
        }
        return data.count <= Self.maximumEncodedImageBytes ? data : nil
    }

    private func decodedCost(
        of source: CGImageSource,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) -> Int? {
        guard !cancellationCheck() else { return nil }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0,
            imageCount <= Self.maximumImageFrameCount
        else {
            return nil
        }
        var total = 0
        for index in 0..<imageCount {
            guard !cancellationCheck() else { return nil }
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(
                    source,
                    index,
                    nil
                ) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                let cost = Self.decodedCost(
                    width: width.intValue,
                    height: height.intValue,
                    bitsPerComponent: (properties[kCGImagePropertyDepth] as? NSNumber)?
                        .intValue ?? 8
                )
            else {
                return nil
            }
            let (nextTotal, overflow) = total.addingReportingOverflow(cost)
            guard !overflow, nextTotal <= Self.maximumDecodedImageCost else {
                return nil
            }
            total = nextTotal
        }
        return total
    }
}
