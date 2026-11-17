#!/bin/sh
# Xcode Cloud runs this after each xcodebuild action. After an archive, it sends the build's debug symbols (dSYMs) to
# Sentry project foon-ios (#28) so crash reports show Foon's function names and lines instead of addresses.
# Source code isn't uploaded (no --include-sources).
#
# Needs SENTRY_AUTH_TOKEN as a secret environment variable in both Xcode Cloud workflows (QA and Production beta):
# an organization token from Sentry → Settings → Auth Tokens. Without it, or if the upload fails, the build still
# succeeds; crash reports just stay unsymbolicated until the next upload.
set -u

[ -n "${CI_ARCHIVE_PATH:-}" ] || exit 0

dsyms="$CI_ARCHIVE_PATH/dSYMs"
if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "warning: SENTRY_AUTH_TOKEN isn't set, so dSYMs weren't sent to Sentry."
  exit 0
fi
if [ ! -d "$dsyms" ]; then
  echo "warning: no dSYMs at $dsyms, so none were sent to Sentry."
  exit 0
fi

if ! brew install getsentry/tools/sentry-cli; then
  echo "warning: couldn't install sentry-cli, so dSYMs weren't sent to Sentry."
  exit 0
fi

if ! sentry-cli debug-files upload --org chris-andrikanich --project foon-ios "$dsyms"; then
  echo "warning: sending dSYMs to Sentry failed."
fi
exit 0
