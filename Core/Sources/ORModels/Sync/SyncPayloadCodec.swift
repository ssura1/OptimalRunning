import Foundation

#if canImport(Compression)
import Compression
#endif

/// Compresses and decompresses the bytes that cross the WatchConnectivity boundary
/// (T-048: "a gzipped `RunEnvelope`").
///
/// **Why this lives in `Core` despite importing an Apple library.** ADR-001 keeps `Core`
/// on the standard library and cross-platform Foundation, and `Compression` is neither.
/// It earns the exception by being the only way to have *one* definition of the format:
/// the watch compresses and the phone decompresses, they live in two separate local
/// packages that cannot see each other, and a codec duplicated across both is a pair of
/// implementations that can silently disagree about framing. Sync is the one place in
/// this project where two independently-written halves must produce byte-identical
/// results, so it gets one implementation that both import — and a cross-tier round-trip
/// test that would be impossible to write if each side owned its own copy.
///
/// The exception is narrow and cheap. `Compression` needs no device, no simulator, and no
/// entitlement; it does not drag `Core` toward requiring Xcode to test. See the note on
/// ADR-001 in `design.md`.
///
/// **On non-Apple platforms this throws rather than passing data through.** A silent
/// identity fallback would let `Core` build on Linux while producing bytes the phone
/// cannot read, and that failure would surface as "some runs never sync" long after the
/// commit that caused it. Throwing is honest: nothing on Linux has a `WCSession` to talk
/// to, so no legitimate caller reaches this.
public enum SyncPayloadCodec {

    public enum CodecError: Error, Equatable, Sendable {
        case unsupportedPlatform
        /// Compression or decompression failed. For decompression this usually means a
        /// truncated transfer, which the ingest path reports as a malformed payload
        /// rather than a crash.
        case failed(operation: String)
        case empty
    }

    /// zlib, not raw DEFLATE and not Apple's LZFSE.
        ///
    /// LZFSE is faster and compresses a little better, but it is Apple-proprietary; zlib
    /// keeps the payload readable by anything, which matters for the diagnostic export
    /// path (NFR-17) and for debugging a transfer by hand.
    #if canImport(Compression)
    private static let algorithm = COMPRESSION_ZLIB
    #endif

    public static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw CodecError.empty }
        #if canImport(Compression)
        return try transform(data, operation: COMPRESSION_STREAM_ENCODE, label: "compress")
        #else
        throw CodecError.unsupportedPlatform
        #endif
    }

    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw CodecError.empty }
        #if canImport(Compression)
        return try transform(data, operation: COMPRESSION_STREAM_DECODE, label: "decompress")
        #else
        throw CodecError.unsupportedPlatform
        #endif
    }

    // MARK: - Convenience

    /// Encode → compress, the exact pair the watch performs before a transfer.
    public static func encode(_ envelope: RunEnvelope) throws -> Data {
        try compress(RunEnvelopeCoder.encode(envelope))
    }

    /// Decompress → decode → validate, the exact pair the phone performs on receipt.
    ///
    /// Decompression failure is mapped to `EnvelopeError.malformed` rather than
    /// surfacing a codec error, because from the ingest path's point of view a truncated
    /// transfer and a corrupted one are the same event with the same handling: NACK the
    /// run and say so.
    public static func decode(_ data: Data) throws -> RunEnvelope {
        let json: Data
        do {
            json = try decompress(data)
        } catch {
            throw EnvelopeError.malformed(reason: "payload could not be decompressed: \(error)")
        }
        return try RunEnvelopeCoder.decode(json)
    }

    // MARK: - Private

    #if canImport(Compression)
    /// Streaming rather than one-shot, because `compression_encode_buffer` requires the
    /// caller to guess an output size up front. For compression that guess is usually
    /// fine; for *de*compression it is unknowable — a 30 KB payload can expand to any
    /// size — and the usual workaround of "allocate 10× and hope" fails exactly on the
    /// large runs that matter most.
    private static func transform(
        _ input: Data,
        operation: compression_stream_operation,
        label: String
    ) throws -> Data {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }

        guard compression_stream_init(streamPointer, operation, algorithm) == COMPRESSION_STATUS_OK
        else { throw CodecError.failed(operation: label) }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var output = Data()

        // `withUnsafeBytes` scopes the source pointer to this closure, so the whole
        // stream loop runs inside it rather than caching a pointer that would dangle.
        let result: Result<Data, Error> = input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return .failure(CodecError.failed(operation: label))
            }

            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count

            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize

                let status = compression_stream_process(
                    streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )

                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(destination, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    // Buffer filled, more to do. Loop with a fresh destination.
                    continue
                case COMPRESSION_STATUS_END:
                    return .success(output)
                default:
                    return .failure(CodecError.failed(operation: label))
                }
            }
        }

        return try result.get()
    }
    #endif
}
