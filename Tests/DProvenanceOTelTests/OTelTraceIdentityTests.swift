import Foundation
import XCTest
import DProvenanceKit
@testable import DProvenanceOTel

/// Known-answer tests freeze the "v1" derivation scheme: any change to a
/// preimage (including UUID casing, F11) breaks a KAT here, not a production
/// backend's trace correlation.
final class OTelTraceIdentityTests: XCTestCase {
    private let zeroRun = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    func testTraceIDKnownAnswer() {
        XCTAssertEqual(
            OTelTraceIdentity.traceID(forRun: zeroRun),
            "a6ebe665484798a577c394395e8b9925"
        )
    }

    func testRootSpanIDKnownAnswer() {
        XCTAssertEqual(
            OTelTraceIdentity.rootSpanID(forRun: zeroRun),
            "7b1e72bff176a414"
        )
    }

    func testSpanIDKnownAnswer() {
        XCTAssertEqual(
            OTelTraceIdentity.spanID(forRun: zeroRun, dpkSpanID: "outer"),
            "625495fa94bfe7cf"
        )
    }

    func testEventSpanIDKnownAnswer() {
        XCTAssertEqual(
            OTelTraceIdentity.eventSpanID(forRun: zeroRun, sequence: 7),
            "03eadf18691fd595"
        )
    }

    /// Pins F11: `UUID.uuidString` is uppercase, but every preimage must use
    /// the lowercased form. The frozen answer below was computed from the
    /// lowercase preimage "dpk-otel:v1:trace:deadbeef-dead-beef-dead-beefdeadbeef".
    func testUppercaseUUIDInputMatchesLowercasePreimage() {
        let upper = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let lower = UUID(uuidString: "deadbeef-dead-beef-dead-beefdeadbeef")!
        XCTAssertEqual(upper.uuidString, "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")

        let expected = "efdc0a78bc03cbf37271c41434264dce"
        XCTAssertEqual(OTelTraceIdentity.traceID(forRun: upper), expected)
        XCTAssertEqual(OTelTraceIdentity.traceID(forRun: lower), expected)
    }

    func testShapesAreLowercaseHex() {
        let run = UUID()
        XCTAssertTrue(isLowercaseHex(OTelTraceIdentity.traceID(forRun: run), count: 32))
        XCTAssertTrue(isLowercaseHex(OTelTraceIdentity.rootSpanID(forRun: run), count: 16))
        XCTAssertTrue(isLowercaseHex(OTelTraceIdentity.spanID(forRun: run, dpkSpanID: "Draft Generation"), count: 16))
        XCTAssertTrue(isLowercaseHex(OTelTraceIdentity.eventSpanID(forRun: run, sequence: .max), count: 16))
    }

    func testSameSpanNameUnderDifferentRunsDiffers() {
        let runA = UUID()
        let runB = UUID()
        XCTAssertNotEqual(
            OTelTraceIdentity.spanID(forRun: runA, dpkSpanID: "outer"),
            OTelTraceIdentity.spanID(forRun: runB, dpkSpanID: "outer")
        )
        XCTAssertNotEqual(
            OTelTraceIdentity.traceID(forRun: runA),
            OTelTraceIdentity.traceID(forRun: runB)
        )
    }

    /// Span names are case-sensitive user data: casing must fork the id.
    func testSpanNameCasingIsSignificant() {
        XCTAssertNotEqual(
            OTelTraceIdentity.spanID(forRun: zeroRun, dpkSpanID: "outer"),
            OTelTraceIdentity.spanID(forRun: zeroRun, dpkSpanID: "Outer")
        )
    }

    func testDerivationsAreStableAcrossCalls() {
        let run = UUID()
        XCTAssertEqual(OTelTraceIdentity.traceID(forRun: run), OTelTraceIdentity.traceID(forRun: run))
        XCTAssertEqual(
            OTelTraceIdentity.eventSpanID(forRun: run, sequence: 3),
            OTelTraceIdentity.eventSpanID(forRun: run, sequence: 3)
        )
    }
}
