import Foundation

/// Transport policy for requests that carry credentials (API keys, Basic auth, tokens).
///
/// Apple's App Transport Security does not apply to command-line tools, CI runners, or
/// apps that opted out, so a mistyped `http://` endpoint would put a bearer key on the
/// wire in cleartext. Credential-bearing requests therefore require `https`, except to
/// loopback hosts (a local collector or dev server never leaves the machine).
public enum DPKTransportSecurity {
    /// `true` when `url` may receive credentials: `https`, or `http` to a loopback host.
    public static func allowsCredentials(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        return isLoopback(host)
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" { return true }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
