import Foundation
import Compression

/// Downloads and extracts Kokoro CoreML models on iOS.
/// The upstream ModelDownloader only supports macOS (uses /usr/bin/tar).
/// This fetcher downloads the tar.gz and extracts using Apple's Compression framework.
enum KokoroModelFetcher {
    static let repo = "Jud/kokoro-coreml"
    static let asset = "kokoro-models.tar.gz"

    static func download(
        to directory: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Get latest release tag
        let tag = try await latestModelTag()


        let url = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(asset)")!

        // Download tar.gz
        let (localURL, response) = try await URLSession.shared.download(from: url, delegate: DownloadDelegate(progress: progress))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }



        // Extract using tar via NSTask alternative — use gunzip + untar via pipes
        // On iOS we don't have /usr/bin/tar, so use a shell-free approach
        let tarball = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        try fm.moveItem(at: localURL, to: tarball)
        defer { try? fm.removeItem(at: tarball) }

        try extractTarGz(tarball, to: directory)

        // Write tag marker
        let tagFile = directory.appendingPathComponent(".model-tag")
        try tag.write(to: tagFile, atomically: true, encoding: .utf8)
    }

    private static func latestModelTag() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "models-v1"
        }
        if let release = json.first(where: { ($0["tag_name"] as? String)?.hasPrefix("models-") == true }),
           let tag = release["tag_name"] as? String {
            return tag
        }
        return "models-v1"
    }

    /// Extract a .tar.gz file to a directory using Foundation APIs.
    /// Uses the zlib decompression built into iOS and a minimal tar parser.
    private static func extractTarGz(_ tarGzURL: URL, to directory: URL) throws {
        let compressedData = try Data(contentsOf: tarGzURL)

        // Decompress gzip
        let decompressed = try decompressGzip(compressedData)


        // Parse tar
        try extractTar(decompressed, to: directory)
    }

    private static func decompressGzip(_ data: Data) throws -> Data {
        guard data.count > 10 else { throw URLError(.cannotDecodeContentData) }
        // Gzip: skip the 10-byte header, then decompress with raw DEFLATE
        // Find the start of the deflate stream (after gzip header)
        var headerSize = 10
        let flags = data[3]
        if flags & 0x04 != 0 { // FEXTRA
            let xlen = Int(data[10]) | (Int(data[11]) << 8)
            headerSize += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME - skip null-terminated string
            var i = headerSize
            while i < data.count && data[i] != 0 { i += 1 }
            headerSize = i + 1
        }
        if flags & 0x10 != 0 { // FCOMMENT - skip null-terminated string
            var i = headerSize
            while i < data.count && data[i] != 0 { i += 1 }
            headerSize = i + 1
        }
        if flags & 0x02 != 0 { headerSize += 2 } // FHCRC

        // Strip gzip header and 8-byte trailer (CRC32 + size)
        let deflateData = data[headerSize..<(data.count - 8)]

        // Use Compression framework for DEFLATE
        let decompressed = try deflateData.withUnsafeBytes { (srcBuf: UnsafeRawBufferPointer) -> Data in
            let srcPtr = srcBuf.baseAddress!.bindMemory(to: UInt8.self, capacity: srcBuf.count)
            // Allocate generous output buffer (tar is ~111MB uncompressed)
            let dstCapacity = 200 * 1024 * 1024
            let dstPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dstPtr.deallocate() }

            let decodedSize = compression_decode_buffer(
                dstPtr, dstCapacity,
                srcPtr, srcBuf.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard decodedSize > 0 else {
                throw URLError(.cannotDecodeContentData)
            }

            return Data(bytes: dstPtr, count: decodedSize)
        }
        return decompressed
    }

    /// Minimal tar archive extractor (POSIX/UStar format).
    private static func extractTar(_ tarData: Data, to directory: URL) throws {
        let fm = FileManager.default
        var offset = 0
        let blockSize = 512
        var fileCount = 0

        while offset + blockSize <= tarData.count {
            let headerData = tarData[offset..<(offset + blockSize)]

            // Check for empty block (end of archive)
            if headerData.allSatisfy({ $0 == 0 }) {

                break
            }

            // Parse filename (first 100 bytes, null-terminated)
            let nameBytes = headerData[headerData.startIndex..<(headerData.startIndex + 100)]
            guard let name = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8),
                  !name.isEmpty else {
                break
            }

            // Parse size (octal string at offset 124, 12 bytes)
            let sizeBytes = headerData[(headerData.startIndex + 124)..<(headerData.startIndex + 136)]
            let sizeStr = String(bytes: sizeBytes.prefix(while: { $0 != 0 && $0 != 0x20 }), encoding: .ascii) ?? "0"
            let fileSize = Int(sizeStr, radix: 8) ?? 0

            // Parse type flag (offset 156)
            let typeFlag = headerData[headerData.startIndex + 156]

            // Check for UStar prefix (offset 345, 155 bytes)
            let prefixBytes = headerData[(headerData.startIndex + 345)..<(headerData.startIndex + 500)]
            let prefix = String(bytes: prefixBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            let fullPath = prefix.isEmpty ? name : "\(prefix)/\(name)"

            let relativePath = fullPath

            // Advance past header
            offset += blockSize

            // Skip macOS resource fork files
            let filename = (relativePath as NSString).lastPathComponent
            if filename.hasPrefix("._") {
                offset += ((fileSize + blockSize - 1) / blockSize) * blockSize
                continue
            }

            let destURL = directory.appendingPathComponent(relativePath)

            switch typeFlag {
            case 0x35, UInt8(ascii: "5"): // Directory
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            case 0, 0x30, UInt8(ascii: "0"): // Regular file
                if fileSize > 0 && offset + fileSize <= tarData.count {
                    let fileData = tarData[offset..<(offset + fileSize)]
                    try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileData.write(to: destURL)
                    fileCount += 1
                }
            default:
                break // Skip other types (symlinks, etc.)
            }

            // Advance past file data (rounded up to block boundary)
            offset += ((fileSize + blockSize - 1) / blockSize) * blockSize
        }
    }
}

/// URLSession download delegate to report progress.
private class DownloadDelegate: NSObject, URLSessionTaskDelegate {
    let progressHandler: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progressHandler = progress
    }
}
