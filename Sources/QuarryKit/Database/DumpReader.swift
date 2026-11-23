import Foundation
import zlib

/// Reads a file an import loads (S-044), plain or gzip-compressed (told by
/// its first bytes, not its name), a buffer at a time. The counterpart of
/// `DumpFile`. One import task reads it at a time, hence unchecked Sendable.
public final class DumpReader: @unchecked Sendable {
    public let url: URL
    /// The file's size on disk.
    public let totalBytes: Int
    public let isCompressed: Bool
    /// Bytes of the file read so far (compressed bytes for a .gz file).
    public private(set) var bytesRead = 0
    private let handle: FileHandle
    private var stream: UnsafeMutablePointer<z_stream>?
    private var input = Data()
    private var inputOffset = 0
    private var atEnd = false
    private var isClosed = false

    public static let chunkSize = 1024 * 1024

    public init(url: URL) throws {
        self.url = url
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DatabaseError(message: "Couldn’t open \(url.lastPathComponent). Check that it exists and you may read it.")
        }
        totalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let magic = (try? handle.read(upToCount: 2)) ?? Data()
        try? handle.seek(toOffset: 0)
        isCompressed = magic.count == 2 && magic[magic.startIndex] == 0x1f && magic[magic.startIndex + 1] == 0x8b
        if isCompressed {
            let zs = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            zs.initialize(to: z_stream())
            // 15 window bits + 32: read a gzip or zlib header, whichever it has.
            guard inflateInit2_(zs, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                zs.deallocate()
                try? handle.close()
                throw DatabaseError(message: "Couldn’t start reading the gzip file.")
            }
            stream = zs
        }
    }

    deinit { close() }

    /// The next bytes of SQL, up to `chunkSize` (more or less for gzip); nil at the end.
    public func read() throws -> [UInt8]? {
        guard !isClosed else { return nil }
        guard stream != nil else {
            let data = try handle.read(upToCount: Self.chunkSize) ?? Data()
            bytesRead += data.count
            return data.isEmpty ? nil : [UInt8](data)
        }
        return try inflateChunk()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let stream {
            inflateEnd(stream)
            stream.deallocate()
            self.stream = nil
        }
        try? handle.close()
    }

    private func inflateChunk() throws -> [UInt8]? {
        guard let stream else { return nil }
        var output = [UInt8]()
        var out = [UInt8](repeating: 0, count: 256 * 1024)
        while output.count < Self.chunkSize {
            if inputOffset >= input.count {
                if atEnd { break }
                input = try handle.read(upToCount: 256 * 1024) ?? Data()
                inputOffset = 0
                bytesRead += input.count
                if input.isEmpty {
                    atEnd = true
                    break
                }
            }
            let status: Int32 = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: Bytef.self).baseAddress!
                stream.pointee.next_in = UnsafeMutablePointer(mutating: base + inputOffset)
                stream.pointee.avail_in = uInt(input.count - inputOffset)
                let status = out.withUnsafeMutableBufferPointer { pointer -> Int32 in
                    stream.pointee.next_out = pointer.baseAddress
                    stream.pointee.avail_out = uInt(pointer.count)
                    return inflate(stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw DatabaseError(message: "\(url.lastPathComponent) isn’t a readable gzip file.")
                }
                inputOffset = input.count - Int(stream.pointee.avail_in)
                output.append(contentsOf: out[0..<(out.count - Int(stream.pointee.avail_out))])
                stream.pointee.next_in = nil
                return status
            }
            // gzip files may hold several members one after another.
            if status == Z_STREAM_END { inflateReset(stream) }
        }
        return output.isEmpty ? nil : output
    }
}
