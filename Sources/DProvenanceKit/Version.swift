/// The version of this library build, including an unpublished release candidate.
///
/// A verification certificate names the tool that produced it, so a reader can reproduce the
/// result years later against the same version rather than whatever is current when they ask.
/// That makes this string load-bearing rather than cosmetic, so
/// `.github/scripts/check-release-surfaces.sh` holds it to the newest numbered heading in
/// CHANGELOG.md — cutting a release without updating it fails CI.
public enum DProvenanceKitVersion {
    public static let current = "0.11.0"
}
