import Foundation

/// A human-readable rendering of a ``ProofPackVerification``.
///
/// `dpk verify --proof-pack` answers an engineer's question — did this pack verify, and how
/// strongly is each artifact bound? A certificate answers a different question, asked by a
/// different reader: a lawyer attaching evidence to a filing, an underwriter at renewal, an
/// auditor assembling a file. Those readers cannot act on an exit code, and they are the ones
/// who decide whether the evidence is worth anything.
///
/// The certificate states, in plain language, what was verified, what the signature does and
/// does not cover, and how to re-verify independently. It deliberately carries the scope limits
/// from `docs/ATTESTATION.md#threat-model` in the body rather than a footnote: a certificate that
/// travels without them invites the reader to believe the signature proves the content is *true*,
/// which it does not, and which no honest attestation can.
///
/// Rendering is pure and deterministic — the caller supplies `issuedAt`, so the same verification
/// renders byte-identically every time and can be committed as a fixture.
public enum ProofPackCertificate {

    /// How strongly, in the reader's terms, the signature covers a given artifact.
    ///
    /// This is the distinction that decides whether a document is evidence or an assertion, so
    /// it is stated in prose rather than left to the reader to infer from an enum name.
    static func bindingProse(_ strength: ProofPackBindingStrength) -> String {
        switch strength {
        case .roleBound:
            return """
            The signature covers both the document's exact bytes and the role it is presented \
            under. Relabelling the document after signing would invalidate this certificate.
            """
        case .valuePresenceOnly:
            return """
            The signature covers the document's exact bytes only. The role and media type shown \
            were asserted by the producer and are NOT covered by the signature — they could have \
            been changed after signing without invalidating the pack. Treat the label as a claim, \
            not as evidence.
            """
        }
    }

    /// Whether the signer's identity was established, or merely internally consistent.
    static func trustProse(_ trust: TraceAttestationTrust) -> String {
        switch trust {
        case .trustedKey:
            return """
            The signing key was matched against a key identifier supplied independently by the \
            verifier, so the signer's identity is established to the strength of that key's \
            custody.
            """
        case .embeddedKeyOnly:
            return """
            The signature is internally valid, but the signer's identity was NOT independently \
            established — verification used the key embedded in the document itself. Anyone can \
            generate a key, sign a substituted document, and produce a pack that verifies this \
            way. Pin the expected key identifier to close this gap.
            """
        }
    }

    /// What a valid attestation does not establish. Kept verbatim in spirit with
    /// `docs/ATTESTATION.md#threat-model` — if that section changes, this must change with it.
    static let scopeLimits: [String] = [
        """
        Truthfulness. The signature proves what the producer recorded. It does not prove that the \
        recorded reasoning occurred as described, or that any claim in the covered material is true.
        """,
        """
        Capture completeness. Events dropped before the document was assembled cannot be recovered \
        by a signature, and this certificate cannot show what was never recorded.
        """,
        """
        Trusted time. The issuance time shown for the signed record is asserted by the \
        producer's clock. It is not corroborated by a timestamping authority.
        """,
        """
        Executing-binary identity. Nothing here establishes which program produced the trace, or \
        that it was the program the producer claims.
        """,
        """
        Regulatory compliance. This certificate is evidence of record integrity. It is not a \
        compliance certification, an audit opinion, or legal advice.
        """,
    ]

    // MARK: - Plain text

    /// A terminal- and email-safe rendering. Suitable for pasting into a memo or a CI log.
    public static func plainText(
        _ verification: ProofPackVerification,
        pack: ProofPackDocument,
        issuedAt: Date,
        toolVersion: String
    ) -> String {
        var out: [String] = []
        let stamp = iso8601(issuedAt)

        out.append("PROOF PACK VERIFICATION CERTIFICATE")
        out.append(String(repeating: "=", count: 62))
        out.append("")

        guard verification.isValid else {
            out.append("RESULT: NOT VERIFIED")
            out.append("")
            out.append("Reason: \(verification.failure.map(String.init(describing:)) ?? "unknown failure")")
            if let attestation = verification.attestation {
                out.append("Signing key ID: \(attestation.keyID)")
            }
            out.append("")
            out.append("This document did not verify. Do not rely on it as evidence of record")
            out.append("integrity. Verified \(stamp) using DProvenanceKit \(toolVersion).")
            return out.joined(separator: "\n") + "\n"
        }

        out.append("RESULT: VERIFIED")
        out.append("Verified at: \(stamp)")
        out.append("Verified with: DProvenanceKit \(toolVersion) (proof pack schema v\(pack.proofPackVersion))")
        out.append("")

        out.append("COVERED DOCUMENTS")
        out.append(String(repeating: "-", count: 62))
        for binding in verification.bindings {
            let artifact = pack.artifacts.indices.contains(binding.artifactIndex)
                ? pack.artifacts[binding.artifactIndex] : nil
            out.append("Role:        \(binding.role)")
            if let mediaType = artifact?.mediaType {
                out.append("Media type:  \(mediaType)")
            }
            out.append("SHA-256:     \(binding.sha256)")
            out.append("Bound by:    event[\(binding.eventIndex)] \(binding.eventTypeIdentifier)")
            out.append("Coverage:    \(wrap(bindingProse(binding.strength), indent: 13))")
            out.append("")
        }

        out.append("SIGNED RECORD")
        out.append(String(repeating: "-", count: 62))
        let attestation = pack.attestation.attestation
        out.append("Run ID:       \(pack.attestation.trace.runID.uuidString.lowercased())")
        out.append("Events:       \(pack.attestation.trace.events.count)")
        out.append("Edges:        \(pack.attestation.trace.edges.count)")
        out.append("Trace digest: \(attestation.traceDigest)")
        out.append("Algorithm:    \(attestation.algorithm.rawValue) / \(attestation.canonicalization.rawValue)")
        out.append("Issued at:    \(iso8601(Date(timeIntervalSince1970: Double(attestation.issuedAtUnixMicroseconds) / 1_000_000)))  (producer's clock)")
        out.append("")

        out.append("SIGNER")
        out.append(String(repeating: "-", count: 62))
        if let attestationResult = verification.attestation {
            out.append("Key ID:       \(attestationResult.keyID)")
            out.append("Identity:     \(wrap(trustProse(attestationResult.trust), indent: 14))")
        }
        out.append("")

        out.append("SCOPE AND LIMITATIONS")
        out.append(String(repeating: "-", count: 62))
        out.append("A valid signature establishes that the covered record has not changed since it")
        out.append("was signed. It does NOT establish:")
        out.append("")
        for limit in scopeLimits {
            out.append("  - \(wrap(limit, indent: 4))")
        }
        out.append("")

        out.append("INDEPENDENT RE-VERIFICATION")
        out.append(String(repeating: "-", count: 62))
        out.append("This certificate is a rendering, not the evidence. Verify the pack yourself:")
        out.append("")
        out.append("    dpk verify --proof-pack --in=<pack.json> --require-role-binding \\")
        out.append("      --trusted-key=\(verification.attestation?.keyID ?? "<expected-key-id>")")
        out.append("")
        out.append("Verification runs offline and makes no network requests.")

        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - HTML

    /// A self-contained HTML certificate — no external stylesheets, scripts, or fonts, so it
    /// renders identically offline and prints to PDF from any browser. That matters: the reader
    /// is often assembling a filing or an audit file, and an artifact that phones out to render
    /// is not one they can archive.
    public static func html(
        _ verification: ProofPackVerification,
        pack: ProofPackDocument,
        issuedAt: Date,
        toolVersion: String
    ) -> String {
        let stamp = iso8601(issuedAt)
        var body = ""

        if verification.isValid {
            body += #"<p class="result ok">VERIFIED</p>"#
        } else {
            body += #"<p class="result bad">NOT VERIFIED</p>"#
            body += "<p class=\"lede\">This document did not verify. Do not rely on it as evidence of record integrity.</p>"
            body += "<table><tr><th>Reason</th><td class=\"mono\">"
            body += esc(verification.failure.map(String.init(describing:)) ?? "unknown failure")
            body += "</td></tr>"
            if let attestation = verification.attestation {
                body += "<tr><th>Signing key ID</th><td class=\"mono\">\(esc(attestation.keyID))</td></tr>"
            }
            body += "</table>"
            return page(body: body, stamp: stamp, toolVersion: toolVersion)
        }

        body += "<table>"
        body += "<tr><th>Verified at</th><td>\(esc(stamp))</td></tr>"
        body += "<tr><th>Verified with</th><td>DProvenanceKit \(esc(toolVersion)) &middot; proof pack schema v\(pack.proofPackVersion)</td></tr>"
        body += "</table>"

        body += "<h2>Covered documents</h2>"
        for binding in verification.bindings {
            let artifact = pack.artifacts.indices.contains(binding.artifactIndex)
                ? pack.artifacts[binding.artifactIndex] : nil
            body += "<table>"
            body += "<tr><th>Role</th><td>\(esc(binding.role))</td></tr>"
            if let mediaType = artifact?.mediaType {
                body += "<tr><th>Media type</th><td class=\"mono\">\(esc(mediaType))</td></tr>"
            }
            body += "<tr><th>SHA-256</th><td class=\"mono break\">\(esc(binding.sha256))</td></tr>"
            body += "<tr><th>Bound by</th><td class=\"mono\">event[\(binding.eventIndex)] \(esc(binding.eventTypeIdentifier))</td></tr>"
            let cls = binding.strength == .roleBound ? "" : #" class="warn""#
            body += "<tr><th>Coverage</th><td\(cls)>\(esc(bindingProse(binding.strength)))</td></tr>"
            body += "</table>"
        }

        let attestation = pack.attestation.attestation
        let signedAt = Date(timeIntervalSince1970: Double(attestation.issuedAtUnixMicroseconds) / 1_000_000)
        body += "<h2>Signed record</h2><table>"
        body += "<tr><th>Run ID</th><td class=\"mono\">\(esc(pack.attestation.trace.runID.uuidString.lowercased()))</td></tr>"
        body += "<tr><th>Events</th><td>\(pack.attestation.trace.events.count)</td></tr>"
        body += "<tr><th>Edges</th><td>\(pack.attestation.trace.edges.count)</td></tr>"
        body += "<tr><th>Trace digest</th><td class=\"mono break\">\(esc(attestation.traceDigest))</td></tr>"
        body += "<tr><th>Algorithm</th><td class=\"mono\">\(esc(attestation.algorithm.rawValue)) / \(esc(attestation.canonicalization.rawValue))</td></tr>"
        body += "<tr><th>Issued at</th><td>\(esc(iso8601(signedAt))) <span class=\"note\">(producer&rsquo;s clock, not a timestamping authority)</span></td></tr>"
        body += "</table>"

        if let attestationResult = verification.attestation {
            let cls = attestationResult.trust == .trustedKey ? "" : #" class="warn""#
            body += "<h2>Signer</h2><table>"
            body += "<tr><th>Key ID</th><td class=\"mono break\">\(esc(attestationResult.keyID))</td></tr>"
            body += "<tr><th>Identity</th><td\(cls)>\(esc(trustProse(attestationResult.trust)))</td></tr>"
            body += "</table>"
        }

        body += "<h2>Scope and limitations</h2>"
        body += "<p>A valid signature establishes that the covered record has not changed since it was signed. It does <strong>not</strong> establish:</p><ul>"
        for limit in scopeLimits {
            body += "<li>\(esc(limit))</li>"
        }
        body += "</ul>"

        body += "<h2>Independent re-verification</h2>"
        body += "<p>This certificate is a rendering, not the evidence itself. Verify the pack yourself &mdash; offline, with no network requests:</p>"
        body += "<pre>dpk verify --proof-pack --in=&lt;pack.json&gt; --require-role-binding \\\n  --trusted-key="
        body += esc(verification.attestation?.keyID ?? "<expected-key-id>")
        body += "</pre>"

        return page(body: body, stamp: stamp, toolVersion: toolVersion)
    }

    // MARK: - Helpers

    private static func page(body: String, stamp: String, toolVersion: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Proof Pack Verification Certificate</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
               max-width: 46rem; margin: 2.5rem auto; padding: 0 1.25rem; }
        h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
        h2 { font-size: 1rem; text-transform: uppercase; letter-spacing: .06em;
             margin: 2rem 0 .6rem; padding-bottom: .3rem; border-bottom: 1px solid currentColor; opacity: .85; }
        .sub { opacity: .7; margin: 0 0 1.5rem; font-size: .9rem; }
        .result { font-size: 1.5rem; font-weight: 700; letter-spacing: .04em; margin: 1.5rem 0; }
        .ok::before { content: "\\2713\\00a0"; }
        .bad::before { content: "\\2717\\00a0"; }
        .lede { font-weight: 600; }
        table { border-collapse: collapse; width: 100%; margin: 0 0 1rem; }
        th, td { text-align: left; vertical-align: top; padding: .4rem .6rem .4rem 0; }
        th { width: 10rem; font-weight: 600; opacity: .75; white-space: nowrap; }
        td + td, tr + tr { border-top: 1px solid rgba(128,128,128,.25); }
        .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; }
        .break { word-break: break-all; }
        .note { opacity: .65; font-size: .85em; }
        .warn { font-weight: 600; }
        ul { padding-left: 1.1rem; } li { margin: .4rem 0; }
        pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85em;
              padding: .8rem; border: 1px solid rgba(128,128,128,.35); border-radius: 4px;
              overflow-x: auto; white-space: pre-wrap; }
        footer { margin-top: 2.5rem; padding-top: .8rem; border-top: 1px solid rgba(128,128,128,.3);
                 font-size: .82rem; opacity: .7; }
        @media print { body { margin: 0; max-width: none; } h2 { break-after: avoid; } table { break-inside: avoid; } }
        </style>
        </head>
        <body>
        <h1>Proof Pack Verification Certificate</h1>
        <p class="sub">Cryptographic verification of AI reasoning-record integrity</p>
        \(body)
        <footer>Generated \(esc(stamp)) by DProvenanceKit \(esc(toolVersion)).
        This certificate is a rendering of a verification result; the proof pack is the evidence.</footer>
        </body>
        </html>
        """
    }

    private static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Stable, timezone-independent stamp. Certificates are archived and compared; a locale- or
    /// zone-dependent rendering would make two verifications of the same pack look different.
    private static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    /// Soft-wrap prose for the fixed-width rendering, continuing lines at `indent` columns.
    private static func wrap(_ text: String, indent: Int, width: Int = 62) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in collapsed {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width - indent {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n" + String(repeating: " ", count: indent))
    }
}
