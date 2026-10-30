#!/bin/zsh
# Syncs Foon/Resources/Localizable.xcstrings with the strings the compiler extracted from source.
# Xcode does this on every IDE build; command-line builds (agents, CI) don't, so run this after
# scripts/test.sh or an xcodebuild build that used build/DerivedData.
#
#   scripts/sync-strings.sh          add new strings to the catalog, drop ones no longer in source
#   scripts/sync-strings.sh --check  fail if the catalog and source disagree (CI)
set -euo pipefail
cd "${0:A:h}/.."

stringsdata_for() {
  reply=(build/DerivedData/Build/Intermediates.noindex/Foon.build/Debug*/$1.build/Objects-normal/*/*.stringsdata(N))
  reply=(${reply:#*ExtractedAppShortcutsMetadata*})
}

sync_catalog() {
  local catalog=$1
  shift
  if [[ "${check:-}" != 1 ]]; then
    xcrun xcstringstool sync "$catalog" --stringsdata "$@"
    return
  fi
  # Compare key sets rather than bytes, so formatting differences between Xcode versions don't fail CI.
  # The scratch copy must keep the name Localizable.xcstrings: xcstringstool matches the catalog to the
  # stringsdata table by file name, and a different name silently syncs nothing.
  local scratch=$(mktemp -d)
  cp "$catalog" "$scratch/Localizable.xcstrings"
  xcrun xcstringstool sync "$scratch/Localizable.xcstrings" --stringsdata "$@"
  local drift=$(python3 -I - "$catalog" "$scratch/Localizable.xcstrings" <<'PY'
import json, sys
committed, synced = (json.load(open(path))["strings"] for path in sys.argv[1:3])
live = {key for key, entry in synced.items() if entry.get("extractionState") != "stale"}
for key in sorted(live - set(committed)):
    print(f"  new in source, missing from the catalog: {key}")
for key in sorted(set(committed) - live):
    print(f"  in the catalog, no longer localized in source: {key}")
PY
)
  rm -rf "$scratch"
  if [[ -n "$drift" ]]; then
    echo "sync-strings: $catalog is out of step with source. Run scripts/sync-strings.sh and commit:" >&2
    echo "$drift" >&2
    exit 1
  fi
}

[[ "${1:-}" == "--check" ]] && check=1

stringsdata_for Foon
if (( ${#reply} == 0 )); then
  echo "sync-strings: no .stringsdata in build/DerivedData; build first (scripts/test.sh)" >&2
  exit 1
fi
sync_catalog Foon/Resources/Localizable.xcstrings "${reply[@]}"

# The share extension is iOS only, so a macOS-only build (scripts/test.sh) has nothing for it; CI builds iOS first.
stringsdata_for FoonShare
if (( ${#reply} > 0 )); then
  sync_catalog FoonShare/Localizable.xcstrings "${reply[@]}"
elif [[ "${check:-}" != 1 ]]; then
  echo "sync-strings: FoonShare skipped; run an iOS build to include it" >&2
fi

[[ "${check:-}" == 1 ]] || exit 0

# A plain String literal never reaches the stringsdata, so the sync can't see it. Catch the usual shapes.
unlocalized=$(grep -rnE 'errorMessage = "|static (let|var) [A-Za-z]+(: String)? = "[A-Z][a-z]+ [^"]*"' Foon FoonShare \
  --include='*.swift' || true)
if [[ -n "$unlocalized" ]]; then
  echo "sync-strings: user-facing text needs String(localized:):" >&2
  echo "$unlocalized" >&2
  exit 1
fi
echo "sync-strings: catalog matches source"
