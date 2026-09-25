import Core
import Foundation
import UniformTypeIdentifiers

public struct FolderIngester: PhotoIngesting {
    public init() {}

    public func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .contentTypeKey, .fileSizeKey]
        let fm = FileManager.default

        let urls: [URL]
        if options.recursive {
            let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsHiddenFiles])
            urls = (enumerator?.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
        } else {
            urls = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys), options: [])
        }

        var bySHA: [String: PhotoRecord] = [:]
        var skipped: [SkippedFile] = []

        for url in urls {
            let rel = relativePath(of: url, base: base)
            let values = try url.resourceValues(forKeys: keys)
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
            let sha = try FileHasher.sha256Hex(of: url)
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

    private func relativePath(of url: URL, base: URL) -> String {
        let full = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
