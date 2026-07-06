import Foundation
import Compression

/// Minimal, dependency-free gzip (RFC 1952) encoder for the OTLP/HTTP exporter.
///
/// Apple's Compression framework emits raw DEFLATE (RFC 1951) for `COMPRESSION_ZLIB`;
/// this wraps that with the gzip header and CRC32/ISIZE trailer so a server that
/// sees `Content-Encoding: gzip` decodes it correctly. Keeping it here preserves the
/// bridge's zero-third-party-dependency guarantee (Compression ships with the OS).
enum OTLPGzip {

    /// Returns nil if the input is empty or compression fails; callers then send the
    /// body uncompressed (and omit the `Content-Encoding` header).
    static func encode(_ input: Data) -> Data? {
        guard !input.isEmpty, let deflated = rawDeflate(input) else { return nil }

        var out = Data()
        out.reserveCapacity(deflated.count + 18)
        // Header (10 bytes): magic 1f 8b, CM=8 (deflate), FLG=0, MTIME=0 (4B),
        // XFL=0, OS=255 (unknown).
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated)
        // Trailer (8 bytes): CRC32 of the original, then ISIZE = original size mod
        // 2^32, both little-endian.
        appendLittleEndian(&out, crc32(input))
        appendLittleEndian(&out, UInt32(truncatingIfNeeded: input.count))
        return out
    }

    private static func rawDeflate(_ input: Data) -> Data? {
        input.withUnsafeBytes { raw -> Data? in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // DEFLATE can slightly expand incompressible input, so size the
            // destination generously; a 0 return means it didn't fit → nil.
            let capacity = input.count + (input.count / 2) + 128
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = compression_encode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        }
    }

    private static func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    /// Standard CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320). Computed
    /// directly (no table) to keep the encoder tiny and dependency-free.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
        }
        return crc ^ 0xffff_ffff
    }
}
