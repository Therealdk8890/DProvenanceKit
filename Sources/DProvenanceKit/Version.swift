/// The released version of this library.
///
/// A verification certificate names the tool that produced it, so a reader can reproduce the
/// result years later against the same version rather than whatever is current when they ask.
/// That makes this string load-bearing rather than cosmetic, so
/// `.github/scripts/check-release-surfaces.sh` holds it to the newest released heading in
/// CHANGELOG.md — cutting a release without updating it fails CI.
public enum DProvenanceKitVersion {
    public static let current = "0.8.0"
}
