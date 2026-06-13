#!/usr/bin/env bash
#
# sign-and-notarize.sh — Developer ID sign + notarize + staple the assembled
# LibreCADmacOS.app.
#
# This is the RELEASE / distribution signing path. It is OPTIONAL and
# credential-gated: with the required env vars set it signs the app with a
# Developer ID Application certificate (hardened runtime + entitlements),
# submits it to Apple's notary service, waits for the result, and staples the
# ticket. With NO credentials set it does NOT fail — it WARNS and falls back to
# the same ad-hoc signature make-app.sh produces, so local/CI runs without an
# Apple Developer account stay green.
#
# Usage:
#   bash macos/scripts/sign-and-notarize.sh [path/to/App.app]
# If no path is given it defaults to macos/build/LibreCADmacOS.app.
#
# Required env vars for a real Developer ID + notarized build:
#   SIGN_IDENTITY     Codesign identity, e.g.
#                       "Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID           Apple Developer Team ID, e.g. "ABCDE12345".
#   KEYCHAIN_PROFILE  Name of a stored notarytool credential profile created with:
#                       xcrun notarytool store-credentials <KEYCHAIN_PROFILE> \
#                         --apple-id <apple-id> --team-id <TEAM_ID> \
#                         --password <app-specific-password>
#
# Optional env vars:
#   ENTITLEMENTS      Path to the entitlements plist
#                     (default: macos/App/LibreCADmacOS.entitlements).
#   SKIP_NOTARIZE     If "1", sign with Developer ID + hardened runtime but
#                     skip the notary submission/staple (useful for a quick
#                     local Developer ID test without a notary profile).
#
# See macos/docs/ci-and-release.md for the full credential setup.
#
# GPLv2-or-later (LibreCAD derivative).
#
set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${MACOS_DIR}/build"
DEFAULT_APP="${BUILD_DIR}/LibreCADmacOS.app"

APP_DIR="${1:-${DEFAULT_APP}}"
ENTITLEMENTS="${ENTITLEMENTS:-${MACOS_DIR}/App/LibreCADmacOS.entitlements}"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "error: app bundle not found at ${APP_DIR}" >&2
    echo "       run 'bash macos/scripts/make-app.sh' first." >&2
    exit 1
fi

# --- Credential gate ---------------------------------------------------------
# If the Developer ID identity is not provided we cannot do a real signature.
# This is the graceful no-op path: warn loudly, ad-hoc sign, exit 0.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "warning: SIGN_IDENTITY is not set — no Developer ID credentials available." >&2
    echo "         Falling back to AD-HOC signing (NOT distributable / notarizable)." >&2
    echo "         Set SIGN_IDENTITY, TEAM_ID, and KEYCHAIN_PROFILE for a signed build." >&2
    echo "         See macos/docs/ci-and-release.md." >&2
    echo "==> Ad-hoc signing ${APP_DIR}"
    codesign --force --sign - "${APP_DIR}"
    echo "==> Verifying signature"
    codesign -dv "${APP_DIR}" 2>&1 | sed 's/^/    /'
    echo "==> Done (ad-hoc fallback): ${APP_DIR}"
    exit 0
fi

# --- Developer ID signing ----------------------------------------------------
if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "error: entitlements file not found at ${ENTITLEMENTS}" >&2
    exit 1
fi

echo "==> Developer ID signing ${APP_DIR}"
echo "    identity:     ${SIGN_IDENTITY}"
echo "    entitlements: ${ENTITLEMENTS}"
# --options runtime enables the hardened runtime (required for notarization).
# --timestamp embeds a secure timestamp (required for notarization).
# --force re-signs over the ad-hoc signature make-app.sh applied.
codesign --force --deep \
    --options runtime \
    --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" \
    "${APP_DIR}"

echo "==> Verifying Developer ID signature"
codesign --verify --strict --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/    /'

# --- Notarization (optional) -------------------------------------------------
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "warning: SKIP_NOTARIZE=1 — Developer ID signed but NOT notarized/stapled." >&2
    echo "==> Done (signed, not notarized): ${APP_DIR}"
    exit 0
fi

if [[ -z "${KEYCHAIN_PROFILE:-}" ]]; then
    echo "warning: KEYCHAIN_PROFILE is not set — the app is Developer ID signed but" >&2
    echo "         CANNOT be notarized. Gatekeeper may still block it on other Macs." >&2
    echo "         Create a notary profile (see macos/docs/ci-and-release.md) and set" >&2
    echo "         KEYCHAIN_PROFILE to notarize + staple." >&2
    echo "==> Done (signed, not notarized): ${APP_DIR}"
    exit 0
fi

# notarytool requires a zip (or other container) of the .app to submit.
NOTARIZE_ZIP="${BUILD_DIR}/$(basename "${APP_DIR%.app}")-notarize.zip"
echo "==> Zipping for notarization: ${NOTARIZE_ZIP}"
rm -f "${NOTARIZE_ZIP}"
# ditto preserves the bundle structure / symlinks correctly for notarization.
/usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${NOTARIZE_ZIP}"

echo "==> Submitting to Apple notary service (profile: ${KEYCHAIN_PROFILE})"
xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --keychain-profile "${KEYCHAIN_PROFILE}" \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "${APP_DIR}"

echo "==> Validating staple"
xcrun stapler validate "${APP_DIR}" 2>&1 | sed 's/^/    /'
# Gatekeeper assessment confirms the app would launch cleanly on other Macs.
spctl --assess --type execute --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/    /' || \
    echo "warning: spctl assessment did not pass; investigate before distributing." >&2

rm -f "${NOTARIZE_ZIP}"
echo "==> Done (signed + notarized + stapled): ${APP_DIR}"
