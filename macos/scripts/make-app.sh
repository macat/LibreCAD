#!/usr/bin/env bash
#
# make-app.sh — assemble a signed LibreCADmacOS.app from the SwiftPM build.
#
# Offline, no Xcode project: builds the executable with SwiftPM, lays out a
# standard .app bundle, copies in the committed Info.plist, and ad-hoc signs.
#
# GPLv2-or-later (LibreCAD derivative).
#
set -euo pipefail

# --- Paths -------------------------------------------------------------------
# Resolve repo-relative paths from this script's location, so it works from any
# cwd and from any git worktree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENGINE_DIR="${MACOS_DIR}/engine"
INFO_PLIST_SRC="${MACOS_DIR}/App/Info.plist"
BUILD_DIR="${MACOS_DIR}/build"
APP_DIR="${BUILD_DIR}/LibreCADmacOS.app"
CONFIG="${CONFIG:-debug}"        # set CONFIG=release for a release build
EXE_NAME="LibreCADmacOS"

echo "==> Building ${EXE_NAME} (${CONFIG}) with SwiftPM"
# --disable-sandbox is required in this environment.
swift build --disable-sandbox --package-path "${ENGINE_DIR}" -c "${CONFIG}" --product "${EXE_NAME}"

BIN_PATH="$(swift build --disable-sandbox --package-path "${ENGINE_DIR}" -c "${CONFIG}" --show-bin-path)/${EXE_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "error: built executable not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXE_NAME}"
cp "${INFO_PLIST_SRC}" "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - "${APP_DIR}"

echo "==> Verifying signature"
codesign -dv "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo "==> Done: ${APP_DIR}"
echo "    executable: ${APP_DIR}/Contents/MacOS/${EXE_NAME}"
