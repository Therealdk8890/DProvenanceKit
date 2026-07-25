import Foundation
import XCTest
@testable import DProvenanceKit

/// A certificate is the artifact a non-engineer acts on — attached to a filing, handed to an
/// underwriter, filed in an audit binder. These tests hold it to the two properties that make
/// it worth anything: it must not overstate what the signature proves, and everything it tells
/// the reader to do must actually work.
final class ProofPackCertificateTests: XCTestCase {
    /// A fixed instant, so rendering is byte-stable and diffable.
    private let issuedAt = Date(timeIntervalSince1970: 1_753_000_000)
    private let toolVersion = "0.7.0"

    private func vectorURL(version: Int) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs")
            .appendingPathComponent("test-vectors")
            .appendingPathComponent("proof-pack-v\(version).json")
    }

    private func loadPack(version: Int) throws -> ProofPackDocument {
        try ProofPackDocument.decodeJSON(try Data(contentsOf: vectorURL(version: version)))
    }

    /// The fixed-width renderer soft-wraps prose across indented continuation lines, so a
    /// sentence that reads contiguously is not contiguous in the output. These assertions are
    /// about what the certificate *says*, not how it is laid out — collapse the whitespace first.
    private func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Valid packs

    func testTextCertificateForV2StatesRoleBoundCoverage() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()
        XCTAssertTrue(result.isValid)

        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )

        XCTAssertTrue(text.contains("RESULT: VERIFIED"))
        XCTAssertTrue(text.contains("claim-proof-report"))
        XCTAssertTrue(text.contains(result.bindings[0].sha256), "the full digest must be present, not truncated")
        XCTAssertTrue(flattened(text).contains("Relabelling the document after signing would invalidate"))
        XCTAssertFalse(
            flattened(text).contains("NOT covered by the signature"),
            "a role-bound pack must not carry the v1 warning"
        )
    }

    func testTextCertificateForV1WarnsThatTheRoleIsProducerAsserted() throws {
        let pack = try loadPack(version: 1)
        let result = pack.verify()
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.bindingStrength, .valuePresenceOnly)

        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )

        XCTAssertTrue(text.contains("RESULT: VERIFIED"))
        // A v1 pack verifies, and saying only that would mislead the reader about the label.
        XCTAssertTrue(flattened(text).contains("NOT covered by the signature"))
        XCTAssertTrue(flattened(text).contains("Treat the label as a claim, not as evidence"))
    }

    /// The scope limits are the difference between evidence and an overclaim. They are not
    /// optional, and they must survive any future reshuffling of the renderer.
    func testEveryValidCertificateCarriesTheScopeLimits() throws {
        for version in [1, 2] {
            let pack = try loadPack(version: version)
            let result = pack.verify()
            let text = ProofPackCertificate.plainText(
                result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
            )
            let html = ProofPackCertificate.html(
                result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
            )
            for marker in ["Truthfulness", "Capture completeness", "Trusted time",
                           "Executing-binary identity", "Regulatory compliance"] {
                XCTAssertTrue(text.contains(marker), "v\(version) text is missing scope limit: \(marker)")
                XCTAssertTrue(html.contains(marker), "v\(version) html is missing scope limit: \(marker)")
            }
            XCTAssertTrue(text.contains("It does NOT establish"))
        }
    }

    /// An unpinned signer is the weakest real-world case and the easiest to gloss over. The
    /// committed vectors are unpinned, so the certificate must say so in plain words.
    func testUnpinnedSignerIsDisclosedNotGlossed() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()
        XCTAssertEqual(result.attestation?.trust, .embeddedKeyOnly)

        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )
        XCTAssertTrue(flattened(text).contains("NOT independently established"))
        XCTAssertTrue(flattened(text).contains("Anyone can generate a key"))
    }

    // MARK: - Failure rendering

    func testInvalidPackRendersNotVerifiedWithTheReason() throws {
        var pack = try loadPack(version: 2)
        // Swap in content that no longer matches the declared digest.
        let tampered = ProofPackArtifact(
            role: pack.artifacts[0].role,
            mediaType: pack.artifacts[0].mediaType,
            encoding: pack.artifacts[0].encoding,
            content: "dGFtcGVyZWQ=",
            sha256: pack.artifacts[0].sha256
        )
        pack = ProofPackDocument(
            proofPackVersion: pack.proofPackVersion,
            attestation: pack.attestation,
            artifacts: [tampered]
        )

        let result = pack.verify()
        XCTAssertFalse(result.isValid)

        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )
        XCTAssertTrue(text.contains("RESULT: NOT VERIFIED"))
        XCTAssertTrue(text.contains("artifactDigestMismatch"))
        XCTAssertTrue(text.contains("Do not rely on it as evidence"))
        // A failed certificate must not display bindings it never established.
        XCTAssertFalse(text.contains("COVERED DOCUMENTS"))
    }

    // MARK: - The instructions must actually work

    /// The certificate tells the reader how to re-verify. An early draft printed
    /// `--trusted-key-id`, a flag the CLI does not accept — so the one instruction a sceptical
    /// reader would actually run was broken. Pin the flag spellings to the parser's own list.
    func testReVerificationCommandUsesRealFlagSpellings() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()
        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )

        XCTAssertTrue(text.contains("--proof-pack"))
        XCTAssertTrue(text.contains("--require-role-binding"))
        XCTAssertTrue(text.contains("--trusted-key="), "must be --trusted-key=, not --trusted-key-id")
        XCTAssertTrue(text.contains("--in="), "--in carries its value with =")
        XCTAssertFalse(text.contains("--trusted-key-id"))
    }

    // MARK: - HTML safety and self-containment

    /// A v1 pack's role is attacker-choosable (that is exactly what `valuePresenceOnly` means),
    /// and the pack still verifies after a relabel. If the certificate interpolated that role
    /// into HTML unescaped, a verifying pack could carry script into a document that gets opened
    /// in a browser and forwarded to a court.
    func testHostileRoleFromAValidV1PackIsEscaped() throws {
        let pack = try loadPack(version: 1)
        let hostile = ProofPackArtifact(
            role: #"<script>alert('xss')</script>"#,
            mediaType: #"text/html" onload="alert(1)"#,
            encoding: pack.artifacts[0].encoding,
            content: pack.artifacts[0].content,
            sha256: pack.artifacts[0].sha256
        )
        let relabelled = ProofPackDocument(
            proofPackVersion: 1,
            attestation: pack.attestation,
            artifacts: [hostile]
        )

        let result = relabelled.verify()
        XCTAssertTrue(result.isValid, "v1 binds the digest only, so a relabel still verifies")

        let html = ProofPackCertificate.html(
            result, pack: relabelled, issuedAt: issuedAt, toolVersion: toolVersion
        )
        XCTAssertFalse(html.contains("<script>"), "hostile role must not reach the document as markup")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains(#"onload="alert(1)"#))
    }

    /// The reader archives this file. Anything fetched at render time would leave the artifact
    /// dependent on a network, and on whoever controls that host.
    func testHTMLIsSelfContained() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()
        let html = ProofPackCertificate.html(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )

        for external in ["http://", "https://", "<script", "@import", "url("] {
            XCTAssertFalse(html.contains(external), "certificate must not reference \(external)")
        }
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("</html>"))
    }

    // MARK: - Determinism

    func testRenderingIsDeterministic() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()

        XCTAssertEqual(
            ProofPackCertificate.plainText(result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion),
            ProofPackCertificate.plainText(result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion)
        )
        XCTAssertEqual(
            ProofPackCertificate.html(result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion),
            ProofPackCertificate.html(result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion)
        )
    }

    /// The stamp is rendered in UTC regardless of the verifying machine's zone, so two people
    /// verifying the same pack do not produce certificates that appear to disagree.
    func testTimestampIsRenderedInUTC() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()
        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: toolVersion
        )
        XCTAssertTrue(text.contains("Verified at: 2025-07-20T08:26:40Z"), "expected a fixed UTC stamp")
    }

    func testVersionConstantIsStamped() throws {
        let pack = try loadPack(version: 2)
        let result = pack.verify()
        let text = ProofPackCertificate.plainText(
            result, pack: pack, issuedAt: issuedAt, toolVersion: DProvenanceKitVersion.current
        )
        XCTAssertTrue(text.contains("DProvenanceKit \(DProvenanceKitVersion.current)"))
    }
}
