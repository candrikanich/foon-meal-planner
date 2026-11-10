#!/bin/sh
# Xcode Cloud runs this right after cloning. The project isn't committed (XcodeGen makes it), and the hosted
# Supabase URL and key come from the workflow's environment variables into a gitignored xcconfig:
# - scheme "Foon Prod" (the production build, tags beta/*): PROD_SUPABASE_URL and PROD_SUPABASE_ANON_KEY into
#   Prod.local.xcconfig, and only Foon production's URL;
# - any other scheme (the QA build, tags testflight/*): SUPABASE_URL and SUPABASE_ANON_KEY into Staging.local.xcconfig,
#   and never production's URL, so a QA build can't write to real families' data.
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:?}"

PROD_REF="itnhdikhdsujklaimqqd"
PROD_URL="https://$PROD_REF.supabase.co"

# `//` starts an xcconfig comment, so the URL's slashes are escaped the way the example file shows.
write_config() {
  # shellcheck disable=SC2016 # $() is literal: the xcconfig escape, not a command.
  escaped_url=$(printf '%s' "$2" | tr -d '[:space:]' | sed 's#//#/$()/#')
  printf 'SUPABASE_URL = %s\nSUPABASE_ANON_KEY = %s\n' "$escaped_url" "$3" > "Config/$1.local.xcconfig"
}

# Whitespace, trailing slashes and case don't change the host (the app trims the URL), so compare without them.
normalized() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | sed 's#/*$##'
}

if [ "${CI_XCODE_SCHEME:-}" = "Foon Prod" ]; then
  : "${PROD_SUPABASE_URL:?Set PROD_SUPABASE_URL in the production Xcode Cloud workflow environment}"
  : "${PROD_SUPABASE_ANON_KEY:?Set PROD_SUPABASE_ANON_KEY in the production Xcode Cloud workflow environment}"
  if [ "$(normalized "$PROD_SUPABASE_URL")" != "$PROD_URL" ]; then
    echo "error: PROD_SUPABASE_URL is not Foon production ($PROD_URL). Nothing was configured." >&2
    exit 1
  fi
  write_config Prod "$PROD_SUPABASE_URL" "$PROD_SUPABASE_ANON_KEY"
else
  : "${SUPABASE_URL:?Set SUPABASE_URL in the Xcode Cloud workflow environment}"
  : "${SUPABASE_ANON_KEY:?Set SUPABASE_ANON_KEY in the Xcode Cloud workflow environment}"
  # Any URL naming production's project is refused, not only the exact one: a QA build fails closed too.
  case "$(normalized "$SUPABASE_URL")" in *"$PROD_REF"*)
    echo "error: a QA build (scheme ${CI_XCODE_SCHEME:-unknown}) can't point at Foon production." \
      "Nothing was configured." >&2
    exit 1 ;;
  esac
  write_config Staging "$SUPABASE_URL" "$SUPABASE_ANON_KEY"
fi

brew install xcodegen
xcodegen generate
