import Foundation
import XCTest
import Compression
@testable import DProvenanceOTel

/// Decodes gzip in tests to prove the encoder's framing is valid, using only the
/// same Compression framework the encoder uses (raw DEFLATE on the middle bytes).
/// Shared with the exporter test that asserts a compressed body round-trips.
enum GzipRoundTrip {
    static func gunzip(_ gz: Data) -> Data? {
        guard gz.count > 18, gz[gz.startIndex] == 0x1f,
              gz[gz.startIndex + 1] == 0x8b, gz[gz.startIndex + 2] == 0x08 else { return nil }
        let deflated = gz.subdata(in: (gz.startIndex + 10)..<(gz.endIndex - 8))
        let isize = littleEndian32(gz.suffix(4))
        return rawInflate(deflated, hint: Int(isize))
    }

    static func littleEndian32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        Array(bytes).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func rawInflate(_ deflated: Data, hint: Int) -> Data? {
        deflated.withUnsafeBytes { raw -> Data? in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let capacity = max(hint, 64)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let n = compression_decode_buffer(dst, capacity, src, deflated.count, nil, COMPRESSION_ZLIB)
            guard n > 0 else { return nil }
            return Data(bytes: dst, count: n)
        }
    }
}

final class OTLPGzipTests: XCTestCase {

    func testRoundTripsToOriginal() throws {
        let original = Data(String(repeating: "provenance ", count: 500).utf8)
        let gz = try XCTUnwrap(OTLPGzip.encode(original))

        XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 0x08], "gzip magic + deflate method")
        XCTAssertLessThan(gz.count, original.count, "repetitive input should actually compress")

        let back = try XCTUnwrap(GzipRoundTrip.gunzip(gz))
        XCTAssertEqual(back, original)
    }

    func testTrailerCarriesCorrectCrcAndSize() throws {
        let original = Data("the quick brown fox jumps over the lazy dog".utf8)
        let gz = try XCTUnwrap(OTLPGzip.encode(original))

        let crc = GzipRoundTrip.littleEndian32(gz[(gz.endIndex - 8)..<(gz.endIndex - 4)])
        XCTAssertEqual(crc, OTLPGzip.crc32(original), "trailer CRC32 must match the input")

        let isize = GzipRoundTrip.littleEndian32(gz.suffix(4))
        XCTAssertEqual(Int(isize), original.count, "trailer ISIZE must be the input length")
    }

    func testCrc32MatchesKnownVector() {
        // Canonical CRC-32 test vector: crc32("123456789") == 0xCBF43926.
        XCTAssertEqual(OTLPGzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(OTLPGzip.encode(Data()), "callers fall back to sending uncompressed")
    }
}
