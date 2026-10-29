#!/bin/sh
# Xcode Cloud runs this right after cloning. The project isn't committed (XcodeGen makes it), and the hosted
# Supabase URL and key come from the workflow's environment variables into the gitignored Staging config.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

: "${SUPABASE_URL:?Set SUPABASE_URL in the Xcode Cloud workflow's environment}"
: "${SUPABASE_ANON_KEY:?Set SUPABASE_ANON_KEY in the Xcode Cloud workflow's environment}"

# `//` starts an xcconfig comment, so the URL's slashes are escaped the way the example file shows.
escaped_url=$(printf '%s' "$SUPABASE_URL" | sed 's#//#/$()/#')
# Staging only: a Release (prod) archive still fails without its own Prod.local.xcconfig, by design.
printf 'SUPABASE_URL = %s\nSUPABASE_ANON_KEY = %s\n' "$escaped_url" "$SUPABASE_ANON_KEY" > Config/Staging.local.xcconfig

brew install xcodegen
xcodegen generate
