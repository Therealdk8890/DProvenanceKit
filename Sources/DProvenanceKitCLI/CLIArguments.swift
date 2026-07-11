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

    var mode: Mode = .evaluate
    var gate = false
    var minF1: Double?
    var caseName: String?
    var outPath: String?
    var inPath: String?
    /// Normalized (lowercased) 64-hex-character signer key IDs.
    var trustedKeyIDs: Set<String> = []
}

enum CLIArguments {
    /// Flags each mode accepts. `=` marks a flag that carries a value. Anything not
    /// listed — including a value-flag given bare, like `--trusted-key` with no `=` —
    /// is rejected rather than ignored.
    private static let booleanFlags: [CLIInvocation.Mode: Set<String>] = [
        .evaluate: ["--gate"],
        .diagnose: [], .stability: [], .webExport: [], .attestDemo: [], .verify: [],
    ]
    private static let valueFlags: [CLIInvocation.Mode: Set<String>] = [
        .evaluate: ["--min-f1"],
        .diagnose: [], .stability: [],
        .webExport: ["--case", "--out"],
        .attestDemo: ["--out"],
        .verify: ["--in", "--trusted-key"],
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
                default:
                    throw CLIArgumentError.unknownFlag(raw)
                }
            }
        }

        if invocation.minF1 != nil, !invocation.gate {
            throw CLIArgumentError.minF1RequiresGate
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
