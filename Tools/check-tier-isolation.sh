#!/usr/bin/env bash
# AC-FR-K-1-4 — the two watch tiers share no source file and no build dependency
# outside Core.
#
# ## Why this gate exists
#
# ADR-002 accepts duplication between Apps/WatchModern and Apps/WatchLegacy as the price of
# being able to delete the Legacy tier as one directory and one CI job when Xcode 27's SDK
# becomes mandatory (CON-2, R-1). That isolation is load-bearing in one direction only: it stops
# Legacy's removal from regressing Modern.
#
# It does nothing to stop the tiers *drifting apart* — that is R-7, and its mitigation is
# entirely test-side (the shared fixtures and goldens of AC-FR-K-1-2). So the pressure this gate
# resists is the reasonable-sounding instinct that follows from noticing the drift risk: "these
# two files are nearly identical, let me just share one." Sharing a file would satisfy R-7 while
# violating AC-FR-K-1-4 and destroying the removability that motivated the split. Duplication is
# the decision; this gate keeps the decision from being quietly reversed.
#
# ## What is checked, and what is deliberately not
#
# Checked:
#   1. No symlink or hard link makes one file appear in both trees.
#   2. Neither tier's Swift sources import the other tier's module.
#   3. Neither tier's build configuration references a path inside the other tree.
#
# NOT checked: whether files in the two trees have similar or identical *content*. Two
# byte-identical files in the two trees are exactly what ADR-002 sanctions. Flagging that would
# invert the requirement.
#
# Prose is not scanned for path references — only build configuration is — because the tier
# files legitimately discuss each other at length, and a gate that punished a comment for
# explaining the divergence would push the explanation out of the code. Same reasoning as
# check-no-availability.sh's comment stripping.
set -euo pipefail
cd "$(dirname "$0")/.."

MODERN=Apps/WatchModern
LEGACY=Apps/WatchLegacy

status=0
fail() { echo "::error::$1"; status=1; }

# Nothing to check until both tiers exist.
if [ ! -d "$MODERN" ] || [ ! -d "$LEGACY" ]; then
  echo "ok: tier isolation not applicable (both watch tiers not yet present)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Link-level sharing.
#
# A symlink into the sibling tree, or a hard link shared between them, is the most literal
# possible violation: one file, two targets. Hard links are found by inode collision, which is
# why `-samefile` is not used — it needs a nominated file, and the question here is whether *any*
# pair collides.
# ---------------------------------------------------------------------------
for pair in "$MODERN:$LEGACY" "$LEGACY:$MODERN"; do
  here=${pair%%:*}
  there=${pair##*:}

  while IFS= read -r link; do
    # `realpath` follows the symlink itself and yields the final absolute path. An earlier
    # version cd'd into the link's directory and *then* ran `readlink "$link"` on the
    # still-repo-relative path, which resolved to nothing — so `target` was always empty and
    # this check silently passed on a real planted symlink. Verified failing now.
    target=$(realpath "$link" 2>/dev/null || true)
    case "$target" in
      *"/$there/"*) fail "$link is a symlink into $there (AC-FR-K-1-4)" ;;
    esac
  done < <(find "$here" -type l -not -path '*/.build/*' -print)
done

# Inode collisions across the two trees.
collisions=$(
  {
    find "$MODERN" -type f -name '*.swift' -not -path '*/.build/*' -exec stat -f '%i' {} \;
    find "$LEGACY" -type f -name '*.swift' -not -path '*/.build/*' -exec stat -f '%i' {} \;
  } | sort | uniq -d
)
if [ -n "$collisions" ]; then
  fail "a Swift file is hard-linked into both watch tiers (AC-FR-K-1-4)"
  echo "$collisions" | sed 's|^|  shared inode: |'
fi

# ---------------------------------------------------------------------------
# 2. Module-level dependency.
#
# The tier support packages are the only importable non-Core modules either tier owns, so an
# `import` of the sibling's module is precisely "a build dependency on the other outside Core".
# Anchored to a real import statement so prose mentioning the module name stays legal.
# ---------------------------------------------------------------------------
check_imports() {
  local dir=$1 forbidden=$2
  while IFS= read -r file; do
    if matches=$(grep -nE "^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+$forbidden\b" \
      "$file" 2>/dev/null); then
      fail "$file imports $forbidden across the tier boundary (AC-FR-K-1-4)"
      echo "$matches" | sed "s|^|  $file:|"
    fi
  done < <(find "$dir" -name '*.swift' -not -path '*/.build/*' -print)
}
check_imports "$LEGACY" WatchSupport
check_imports "$MODERN" LegacySupport

# ---------------------------------------------------------------------------
# 3. Path references in build configuration.
#
# xcodegen manifests, SwiftPM manifests, and the generated pbxproj. A `path:` or `.package(path:)`
# reaching into the sibling tree would wire the dependency even with no import present yet.
#
# Comments are stripped first — `#` for YAML, `//` for Swift — for the same reason
# check-no-availability.sh does it: these manifests carry long explanations of the tier split,
# and those explanations name the other tree.
# ---------------------------------------------------------------------------
check_config() {
  local dir=$1 forbidden=$2
  while IFS= read -r file; do
    case "$file" in
      *.yml|*.yaml) stripped=$(sed 's|#.*||' "$file") ;;
      *.swift)      stripped=$(sed 's|//.*||' "$file") ;;
      *)            stripped=$(cat "$file") ;;
    esac
    if matches=$(printf '%s\n' "$stripped" | grep -nE "$forbidden"); then
      fail "$file references the $forbidden tree in build configuration (AC-FR-K-1-4)"
      echo "$matches" | sed "s|^|  $file:|"
    fi
  done < <(find "$dir" \
    \( -name 'project.yml' -o -name 'Package.swift' -o -name 'project.pbxproj' \) \
    -not -path '*/.build/*' -print)
}
check_config "$LEGACY" 'WatchModern'
check_config "$MODERN" 'WatchLegacy'

[ $status -eq 0 ] && echo "ok: watch tiers share no file and no cross-tier build dependency"
exit $status
