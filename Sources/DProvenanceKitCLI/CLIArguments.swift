import Foundation

/// Why an invocation was rejected. Every case maps to exit code 2: an argument the
/// CLI does not fully understand must stop the run, never silently weaken it — a
/// mistyped `--trusted-key` or `--min-f1` that "parses to nothing" would otherwise
/// downgrade a security check while still reporting success.
enum CLIArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownMode(String)
    case unexpectedPositional(String)
    case unknownFlag(String)
    case duplicateFlag(String)
    case emptyValue(String)
    case invalidValue(flag: String, value: String, reason: String)
    case minF1RequiresGate
    case requireRoleBindingRequiresProofPack
    case certificateRequiresProofPack
    case outRequiresCertificate
    case missingRequiredFlag(String)

    var description: String {
        switch self {
        case .unknownMode(let mode):
            return "unknown mode '\(mode)'"
        case .unexpectedPositional(let arg):
            return "unexpected argument '\(arg)'"
        case .unknownFlag(let flag):
            return "unknown flag '\(flag)'"
        case .duplicateFlag(let flag):
            return "flag '\(flag)' was given more than once"
        case .emptyValue(let flag):
            return "flag '\(flag)' requires a non-empty value"
        case .invalidValue(let flag, let value, let reason):
            return "invalid value '\(value)' for '\(flag)': \(reason)"
        case .minF1RequiresGate:
            return "--min-f1 has no effect without --gate; pass --gate or drop --min-f1"
        case .requireRoleBindingRequiresProofPack:
            return "--require-role-binding only applies to proof packs; pass --proof-pack or drop it"
        case .certificateRequiresProofPack:
            return "--certificate only applies to proof packs; pass --proof-pack or drop it"
        case .outRequiresCertificate:
            return "verify --out writes a certificate; pass --certificate=text|html or drop --out"
        case .missingRequiredFlag(let flag):
            return "missing required flag \(flag)"
        }
    }
}

/// A fully validated CLI invocation. Construction is all-or-nothing: if any argument
/// is unknown, malformed, duplicated, or out of range, `parse` throws and nothing runs.
struct CLIInvocation: Equatable {
    enum Mode: String, CaseIterable {
        case evaluate
        case diagnose
        case stability
        case webExport = "web-export"
        case attestDemo = "attest-demo"
        case verify
    }

    /// How a certificate is rendered. Both carry identical content; the choice is about the
    /// reader's medium, not the strength of the claim.
    enum CertificateFormat: String, CaseIterable {
        /// Fixed-width, safe to paste into a memo, an email, or a CI log.
        case text
        /// Self-contained HTML — no external assets, prints to PDF from any browser.
        case html
    }

    var mode: Mode = .evaluate
    var gate = false
    var minF1: Double?
    var caseName: String?
    var outPath: String?
    var inPath: String?
    /// verify: treat `--in` as a proof pack (attestation + embedded artifacts).
    var proofPack = false
    /// verify --proof-pack: fail a v1 (value-presence-only) pack instead of accepting it
    /// with a warning — require the role to be signer-vouched (v2).
    var requireRoleBinding = false
    /// verify --proof-pack: render a human-readable certificate instead of the engineer-facing
    /// summary. The exit code is unchanged — a certificate is a rendering of the verification,
    /// never a second opinion about it.
    var certificate: CertificateFormat?
    /// Normalized (lowercased) 64-hex-character signer key IDs.
    var trustedKeyIDs: Set<String> = []
}

enum CLIArguments {
    /// Flags each mode accepts. `=` marks a flag that carries a value. Anything not
    /// listed — including a value-flag given bare, like `--trusted-key` with no `=` —
    /// is rejected rather than ignored.
    private static let booleanFlags: [CLIInvocation.Mode: Set<String>] = [
        .evaluate: ["--gate"],
        .diagnose: [], .stability: [], .webExport: [], .attestDemo: [],
        .verify: ["--proof-pack", "--require-role-binding"],
    ]
    private static let valueFlags: [CLIInvocation.Mode: Set<String>] = [
        .evaluate: ["--min-f1"],
        .diagnose: [], .stability: [],
        .webExport: ["--case", "--out"],
        .attestDemo: ["--out"],
        .verify: ["--in", "--trusted-key", "--certificate", "--out"],
    ]

    static func parse(_ args: [String]) throws -> CLIInvocation {
        var invocation = CLIInvocation()

        // The mode is the first non-flag argument; more than one is a mistake, not
        // something to guess about.
        let positional = args.filter { !$0.hasPrefix("-") }
        if let first = positional.first {
            guard let mode = CLIInvocation.Mode(rawValue: first) else {
                throw CLIArgumentError.unknownMode(first)
            }
            invocation.mode = mode
        }
        if positional.count > 1 {
            throw CLIArgumentError.unexpectedPositional(positional[1])
        }

        let allowedBoolean = booleanFlags[invocation.mode] ?? []
        let allowedValue = valueFlags[invocation.mode] ?? []
        var seen = Set<String>()

        for raw in args where raw.hasPrefix("-") {
            if let equals = raw.firstIndex(of: "=") {
                let name = String(raw[..<equals])
                let value = String(raw[raw.index(after: equals)...])
                guard allowedValue.contains(name) else {
                    throw CLIArgumentError.unknownFlag(name)
                }
                guard !value.isEmpty else {
                    throw CLIArgumentError.emptyValue(name)
                }
                // --trusted-key is repeatable (a set of pinned keys never weakens
                // verification); every other value flag is single-shot because a
                // second occurrence makes the intended value ambiguous.
                if name != "--trusted-key", !seen.insert(name).inserted {
                    throw CLIArgumentError.duplicateFlag(name)
                }
                try apply(name: name, value: value, to: &invocation)
            } else {
                guard allowedBoolean.contains(raw) else {
                    throw CLIArgumentError.unknownFlag(raw)
                }
                if !seen.insert(raw).inserted {
                    throw CLIArgumentError.duplicateFlag(raw)
                }
                switch raw {
                case "--gate":
                    invocation.gate = true
                case "--proof-pack":
                    invocation.proofPack = true
                case "--require-role-binding":
                    invocation.requireRoleBinding = true
                default:
                    throw CLIArgumentError.unknownFlag(raw)
                }
            }
        }

        if invocation.minF1 != nil, !invocation.gate {
            throw CLIArgumentError.minF1RequiresGate
        }
        if invocation.requireRoleBinding, !invocation.proofPack {
            throw CLIArgumentError.requireRoleBindingRequiresProofPack
        }
        if invocation.certificate != nil, !invocation.proofPack {
            throw CLIArgumentError.certificateRequiresProofPack
        }
        // verify only writes a file when rendering a certificate. Accepting a bare --out
        // printed to stdout and left the requested file unwritten, so a script checking
        // for that file read a stale (or missing) verdict.
        if invocation.mode == .verify, invocation.outPath != nil, invocation.certificate == nil {
            throw CLIArgumentError.outRequiresCertificate
        }
        if invocation.mode == .verify, invocation.inPath == nil {
            throw CLIArgumentError.missingRequiredFlag("--in=<attestation.json>")
        }
        return invocation
    }

    private static func apply(
        name: String,
        value: String,
        to invocation: inout CLIInvocation
    ) throws {
        switch name {
        case "--certificate":
            guard let format = CLIInvocation.CertificateFormat(rawValue: value.lowercased()) else {
                throw CLIArgumentError.invalidValue(
                    flag: name, value: value,
                    reason: "expected one of: \(CLIInvocation.CertificateFormat.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            invocation.certificate = format
        case "--min-f1":
            guard let parsed = Double(value), parsed.isFinite else {
                throw CLIArgumentError.invalidValue(
                    flag: name, value: value,
                    reason: "expected a finite number between 0 and 1"
                )
            }
            guard (0.0...1.0).contains(parsed) else {
                throw CLIArgumentError.invalidValue(
                    flag: name, value: value,
                    reason: "F1 baselines must be between 0 and 1"
                )
            }
            invocation.minF1 = parsed
        case "--trusted-key":
            let normalized = value.lowercased()
            // isASCII matters: Character.isHexDigit also matches fullwidth
            // compatibility forms (U+FF10…), which can never equal a real key ID —
            // they must fail here as malformed, not later as "signer not trusted".
            guard normalized.count == 64,
                  normalized.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw CLIArgumentError.invalidValue(
                    flag: name, value: value,
                    reason: "expected a 64-character hex key ID (see `verify` output or attest-demo's signer key ID)"
                )
            }
            invocation.trustedKeyIDs.insert(normalized)
        case "--case":
            invocation.caseName = value
        case "--out":
            invocation.outPath = value
        case "--in":
            invocation.inPath = value
        default:
            // Unreachable: `parse` only routes whitelisted flags here.
            throw CLIArgumentError.unknownFlag(name)
        }
    }
}

/// Neutralizes attacker-controlled text before it reaches a terminal or CI log. A
/// verified document's labels (artifact roles, event type identifiers, decoding-error
/// paths) are chosen by whoever produced the file; raw ESC/CSI sequences could rewrite
/// earlier lines (e.g. paint "VALID" over "INVALID"), and bidi overrides could reorder
/// what a reviewer reads. Control, bidi-control and other format scalars are shown as
/// `\u{XXXX}`; everything else, including non-ASCII text, passes through.
enum TerminalText {
    static func sanitize(_ text: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isUnsafe(scalar) {
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Sanitizes each line, keeping the line breaks themselves (for multi-line renderings
    /// such as the text certificate, whose labels come from the verified pack).
    static func sanitizeLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { sanitize(String($0)) }
            .joined(separator: "\n")
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true          // C0, DEL, C1 (incl. ESC, CSI)
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true // bidi controls
        case 0x2028, 0x2029: return true                     // line/paragraph separators
        default: return false
        }
    }
}
