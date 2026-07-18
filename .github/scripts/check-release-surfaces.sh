#!/bin/sh

# Keep active public install/status copy aligned with the newest released
# changelog entry. Historical changelog entries are deliberately not scanned.
set -eu

script_path=$0
repo_root=$(CDPATH='' cd -- "$(dirname -- "$script_path")/../.." && pwd)

usage() {
  echo "Usage: $script_path [--root PATH | --self-test]" >&2
  exit 2
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    --root)
      [ "$#" -eq 2 ] || usage
      repo_root=$2
      ;;
    --self-test)
      [ "$#" -eq 1 ] || usage
      self_test=1
      ;;
    *)
      usage
      ;;
  esac
fi

check_surfaces() {
  root=$1
  changelog=$root/CHANGELOG.md

  if [ ! -f "$changelog" ]; then
    echo "::error file=CHANGELOG.md::Cannot derive the release version: CHANGELOG.md is missing."
    return 1
  fi

  # The first numeric heading after Unreleased is the newest released version.
  # This POSIX-awk form avoids GNU-only capture arrays.
  release_version=$(
    awk '
      found && $0 ~ /^## \[[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\]/ {
        version = $0
        sub(/^## \[/, "", version)
        sub(/\].*$/, "", version)
        print version
        exit
      }
      $0 == "## [Unreleased]" { found = 1 }
    ' "$changelog"
  )

  if [ -z "$release_version" ]; then
    echo "::error file=CHANGELOG.md::No numeric release heading was found after ## [Unreleased]."
    return 1
  fi

  failures=0

  check_surface() {
    relative_path=$1
    label=$2
    marker=$3
    expected=$4
    file=$root/$relative_path

    if [ ! -f "$file" ]; then
      echo "::error file=$relative_path::$label is missing."
      failures=$((failures + 1))
      return
    fi

    matches=$(grep -F "$marker" "$file" || true)
    if [ -z "$matches" ]; then
      echo "::error file=$relative_path::$label marker is missing; expected release $release_version."
      failures=$((failures + 1))
      return
    fi

    match_count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
    if [ "$match_count" -ne 1 ]; then
      echo "::error file=$relative_path::$label must appear exactly once (found $match_count)."
      failures=$((failures + 1))
      return
    fi

    case "$matches" in
      *"$expected"*)
        echo "OK: $label matches release $release_version."
        ;;
      *)
        echo "::error file=$relative_path::$label does not match release $release_version."
        echo "Observed: $matches"
        failures=$((failures + 1))
        ;;
    esac
  }

  package_url='https://github.com/Therealdk8890/DProvenanceKit'
  check_surface \
    README.md \
    "README install version" \
    ".package(url: \"$package_url\", from:" \
    "from: \"$release_version\")"
  check_surface \
    README.md \
    "README status version" \
    "**Public beta — [" \
    "[$release_version]($package_url/releases/tag/$release_version) is released"
  check_surface \
    COMMERCIAL.md \
    "COMMERCIAL install version" \
    ".package(url: \"$package_url\", from:" \
    "from: \"$release_version\")"
  check_surface \
    site/index.html \
    "site install version" \
    ".package(url: <span class=\"str\">\"$package_url\"</span>, from:" \
    "from: <span class=\"str\">\"$release_version\"</span>)"

  if [ "$failures" -ne 0 ]; then
    echo "Release-surface guard failed with $failures mismatch(es)."
    return 1
  fi

  echo "All active public release surfaces match $release_version."
}

self_test() {
  fixture=$(mktemp -d "${TMPDIR:-/tmp}/dpk-release-surfaces.XXXXXX")
  trap 'rm -rf "$fixture"' EXIT HUP INT TERM
  mkdir -p "$fixture/site"

  printf '%s\n' \
    '# Changelog' \
    '## [Unreleased]' \
    'Pending work mentions 1.2.3 but is not a release heading.' \
    '## [9.8.7] - 2099-01-01' \
    '## [1.2.3] - 2020-01-01' > "$fixture/CHANGELOG.md"
  printf '%s\n' \
    'dependencies: [.package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "9.8.7")]' \
    '**Public beta — [9.8.7](https://github.com/Therealdk8890/DProvenanceKit/releases/tag/9.8.7) is released; APIs may evolve.**' > "$fixture/README.md"
  printf '%s\n' \
    '.package(url: "https://github.com/Therealdk8890/DProvenanceKit", from: "9.8.7")' > "$fixture/COMMERCIAL.md"
  printf '%s\n' \
    '.package(url: <span class="str">"https://github.com/Therealdk8890/DProvenanceKit"</span>, from: <span class="str">"9.8.7"</span>)' > "$fixture/site/index.html"

  check_surfaces "$fixture" >/dev/null

  printf '%s\n' \
    '.package(url: <span class="str">"https://github.com/Therealdk8890/DProvenanceKit"</span>, from: <span class="str">"9.8.6"</span>)' > "$fixture/site/index.html"
  if check_surfaces "$fixture" >/dev/null 2>&1; then
    echo "Self-test failed: a stale site version was accepted." >&2
    return 1
  fi

  echo "Release-surface guard self-test passed."
}

if [ "${self_test:-0}" -eq 1 ]; then
  self_test
else
  check_surfaces "$repo_root"
fi
