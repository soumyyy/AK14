import Core
import Foundation
import UniformTypeIdentifiers

public struct FolderIngester: PhotoIngesting {
    public init() {}

    public func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IngestError.notADirectory(folder.lastPathComponent)
        }
        let excluded = options.excludedDirectories.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .contentTypeKey, .fileSizeKey, .isPackageKey]
        let fm = FileManager.default
        var skipped: [SkippedFile] = []

        func isExcluded(_ url: URL) -> Bool {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        var urls: [URL] = []
        if options.recursive {
            final class Failures: @unchecked Sendable { var items: [(URL, Error)] = [] }
            let failures = Failures()
            let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsPackageDescendants],
                                           errorHandler: { url, error in failures.items.append((url, error)); return true })
            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if isExcluded(url) || url.lastPathComponent.hasPrefix(".") && values?.isDirectory == true {
                    enumerator?.skipDescendants(); continue
                }
                if values?.isDirectory == true && values?.isPackage != true { continue }
                urls.append(url)
            }
            for (url, error) in failures.items {
                skipped.append(SkippedFile(relativePath: relativePath(of: url, base: base), reason: .unreadable,
                                           detail: Self.describe(error)))
            }
        } else {
            urls = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys), options: [])
                .filter { !isExcluded($0) }
        }

        var bySHA: [String: PhotoRecord] = [:]
        for url in urls {
            let rel = relativePath(of: url, base: base)
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: keys) } catch {
                skipped.append(SkippedFile(relativePath: rel, reason: .unreadable, detail: Self.describe(error))); continue
            }
            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                skipped.append(SkippedFile(relativePath: rel, reason: .hiddenFile)); continue
            }
            if values.isDirectory == true {
                skipped.append(SkippedFile(relativePath: rel, reason: .directory)); continue
            }
            guard let type = values.contentType else {
                skipped.append(SkippedFile(relativePath: rel, reason: .unsupportedType)); continue
            }
            if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
                skipped.append(SkippedFile(relativePath: rel, reason: .video, detail: type.identifier)); continue
            }
            guard type.conforms(to: .image) else {
                skipped.append(SkippedFile(relativePath: rel, reason: .unsupportedType, detail: type.identifier)); continue
            }
            guard let meta = MetadataReader.read(url) else {
                skipped.append(SkippedFile(relativePath: rel, reason: .decodeFailure, detail: type.identifier)); continue
            }
            let sha: String
            do { sha = try FileHasher.sha256Hex(of: url) } catch {
                skipped.append(SkippedFile(relativePath: rel, reason: .unreadable, detail: Self.describe(error))); continue
            }
            if var existing = bySHA[sha] {
                existing.sourceRelativePaths = (existing.sourceRelativePaths + [rel]).sorted()
                bySHA[sha] = existing
            } else {
                bySHA[sha] = PhotoRecord(
                    assetID: AssetID(sha256Hex: sha), contentSHA256: sha, sourceRelativePaths: [rel],
                    byteCount: values.fileSize ?? 0, fileType: type.identifier,
                    pixelWidth: meta.pixelWidth, pixelHeight: meta.pixelHeight,
                    exifOrientation: meta.exifOrientation, metadata: meta.capture)
            }
        }
        return IngestResult(photos: bySHA.values.sorted { $0.assetID < $1.assetID },
                            skipped: skipped.sorted { $0.relativePath < $1.relativePath })
    }

    /// Domain + code only, so absolute paths in error text never reach artifacts.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    private func relativePath(of url: URL, base: URL) -> String {
        let full = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
