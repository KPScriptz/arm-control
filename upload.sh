#!/usr/bin/env bash
#
# Upload the exported IPA to TestFlight.
#
# ⚠️ The App Store Connect app record must already exist. The API CANNOT create one —
# `POST /v1/apps` returns 403 "resource 'apps' does not allow 'CREATE'" — so that step is the
# web UI, once, by hand.
#
# Credentials are the same ones Pivot Trading Cards uses; nothing secret lives in this file.
set -euo pipefail
cd "$(dirname "$0")"

IPA=build/export/ArmControl.ipa
KEY_ID="${ASC_KEY_ID:-38MPLQ99S4}"
ISSUER="${ASC_ISSUER:-5b751f41-9b6d-462a-80f8-9caab7410c8a}"

[ -f "$IPA" ] || { echo "No IPA at $IPA — run ./release.sh first"; exit 1; }

echo "==> Validating (catches problems in seconds, before a slow upload)"
xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"

echo "==> Uploading to TestFlight"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"

echo "==> Done. The build appears in TestFlight after Apple finishes processing (5-15 min)."
echo "    Then clear export compliance and attach it to the internal group."
