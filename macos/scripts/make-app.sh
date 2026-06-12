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
REPO_DIR="$(cd "${MACOS_DIR}/.." && pwd)"
ENGINE_DIR="${MACOS_DIR}/engine"
INFO_PLIST_SRC="${MACOS_DIR}/App/Info.plist"
SAMPLE_DXF_SRC="${REPO_DIR}/librecad/res/dxf/dim_sample.dxf"
FONTS_SRC_DIR="${REPO_DIR}/librecad/support/fonts"
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

# Bundle the launch sample so the .app is path-independent (ContentView loads it
# from Bundle.main; the repo path is only a dev fallback for the bare binary).
if [[ -f "${SAMPLE_DXF_SRC}" ]]; then
    cp "${SAMPLE_DXF_SRC}" "${APP_DIR}/Contents/Resources/dim_sample.dxf"
    echo "    bundled sample: Contents/Resources/dim_sample.dxf"
else
    echo "warning: launch sample not found at ${SAMPLE_DXF_SRC}; app will fall back to the repo path" >&2
fi

# Bundle the .lff stroke fonts (ADR-004) so text/dimension text resolves in the
# bundled app without the repo path. CADFonts looks them up under
# Contents/Resources/fonts (Bundle.main), falling back to the repo path for the
# bare binary. standard.lff (the default) is required; the rest are copied so a
# DXF text style naming another shipped font also resolves.
FONTS_DST_DIR="${APP_DIR}/Contents/Resources/fonts"
if [[ -d "${FONTS_SRC_DIR}" ]]; then
    mkdir -p "${FONTS_DST_DIR}"
    cp "${FONTS_SRC_DIR}"/*.lff "${FONTS_DST_DIR}/"
    font_count=$(find "${FONTS_DST_DIR}" -name '*.lff' | wc -l | tr -d ' ')
    echo "    bundled ${font_count} .lff font(s): Contents/Resources/fonts/"
    if [[ ! -f "${FONTS_DST_DIR}/standard.lff" ]]; then
        echo "warning: standard.lff (default font) not among the bundled fonts" >&2
    fi
else
    echo "warning: fonts dir not found at ${FONTS_SRC_DIR}; bundled app will fall back to the repo path for text" >&2
fi

echo "==> Ad-hoc signing"
codesign --force --sign - "${APP_DIR}"

echo "==> Verifying signature"
codesign -dv "${APP_DIR}" 2>&1 | sed 's/^/    /'

echo "==> Done: ${APP_DIR}"
echo "    executable: ${APP_DIR}/Contents/MacOS/${EXE_NAME}"
