import Foundation
import zlib

/// A file an export writes as it goes, plain or gzip-compressed (S-041).
/// Text arrives in pieces; nothing holds the whole export in memory.
/// One export task writes it at a time, hence unchecked Sendable.
public final class DumpFile: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    /// zlib keeps a pointer to its stream, so it lives at a fixed address.
    private var stream: UnsafeMutablePointer<z_stream>?
    private var buffer = Data()
    /// Bytes of SQL written so far, before compression.
    public private(set) var bytesWritten = 0
    private var isClosed = false

    public init(url: URL, compression: SQLDump.Compression) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw DatabaseError(message: "Couldn’t create \(url.lastPathComponent). Check that the folder exists and you may write to it.")
        }
        handle = try FileHandle(forWritingTo: url)
        if compression == .gzip {
            let zs = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            zs.initialize(to: z_stream())
            // 15 window bits + 16: a gzip header and trailer rather than raw zlib.
            guard deflateInit2_(zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                zs.deallocate()
                try? handle.close()
                throw DatabaseError(message: "Couldn’t start gzip compression.")
            }
            stream = zs
        }
    }

    public func write(_ text: String) throws {
        guard !text.isEmpty else { return }
        bytesWritten += text.utf8.count
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= 256 * 1024 { try flush(finishing: false) }
    }

    /// Writes what is left and closes the file. Closing twice does nothing.
    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        try flush(finishing: true)
        endStream()
        try handle.close()
    }

    /// Closes the file and deletes it: a cancelled or failed export leaves nothing behind.
    public func discard() {
        endStream()
        if !isClosed { try? handle.close() }
        isClosed = true
        try? FileManager.default.removeItem(at: url)
    }

    private func endStream() {
        guard let stream else { return }
        deflateEnd(stream)
        stream.deallocate()
        self.stream = nil
    }

    private func flush(finishing: Bool) throws {
        defer { buffer.removeAll(keepingCapacity: true) }
        guard let stream else {
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            return
        }
        var output = Data()
        let chunk = 64 * 1024
        var out = [UInt8](repeating: 0, count: chunk)
        try buffer.withUnsafeMutableBytes { (input: UnsafeMutableRawBufferPointer) in
            stream.pointee.next_in = input.bindMemory(to: Bytef.self).baseAddress
            stream.pointee.avail_in = uInt(input.count)
            repeat {
                let produced = try out.withUnsafeMutableBufferPointer { pointer -> Int in
                    stream.pointee.next_out = pointer.baseAddress
                    stream.pointee.avail_out = uInt(chunk)
                    let status = deflate(stream, finishing ? Z_FINISH : Z_NO_FLUSH)
                    guard status != Z_STREAM_ERROR else { throw DatabaseError(message: "Gzip compression failed.") }
                    return chunk - Int(stream.pointee.avail_out)
                }
                output.append(contentsOf: out[0..<produced])
            } while stream.pointee.avail_out == 0
            stream.pointee.next_in = nil
        }
        if !output.isEmpty { try handle.write(contentsOf: output) }
    }
}

/// Where an export writes (S-043): one file, or a file per table in a folder,
/// each opened when its table starts. One export task uses it at a time.
public final class ExportOutput: @unchecked Sendable {
    /// The file for a table's name, in a per-table export.
    public typealias Opener = @Sendable (String) throws -> DumpFile

    private let single: DumpFile?
    private let opener: Opener?
    /// Every file opened so far, in order.
    public private(set) var files: [DumpFile] = []

    /// Everything in one file.
    public init(file: DumpFile) {
        single = file
        opener = nil
        files = [file]
    }

    /// A file per table, made by `opener`.
    public init(perTable opener: @escaping Opener) {
        single = nil
        self.opener = opener
    }

    public var isPerTable: Bool { single == nil }

    /// The one file, or a new one for `table`.
    public func file(for table: String) throws -> DumpFile {
        if let single { return single }
        let file = try opener!(table)
        files.append(file)
        return file
    }

    public var bytesWritten: Int { files.reduce(0) { $0 + $1.bytesWritten } }
    public var urls: [URL] { files.map(\.url) }

    public func close() throws {
        for file in files { try file.close() }
    }

    /// Deletes every file of this export: a cancelled or failed export leaves nothing.
    public func discard() {
        for file in files { file.discard() }
    }
}
