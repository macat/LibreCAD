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
ICON_DIR="${MACOS_DIR}/assets/AppIcon"
ICON_GEN="${ICON_DIR}/make-icon.swift"      # programmatic, offline icon generator
ICON_ICNS="${ICON_DIR}/AppIcon.icns"        # committed fallback (regenerated below)
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

# App icon (Info.plist sets CFBundleIconFile = AppIcon, so the bundle needs
# Contents/Resources/AppIcon.icns). The icon is generated PROGRAMMATICALLY +
# OFFLINE: regenerate the .iconset PNGs from the checked-in CoreGraphics script and
# pack them into the .icns with the system iconutil, so the icon is reproducible
# from source. If regeneration fails (e.g. no Swift on a CI box), fall back to the
# committed AppIcon.icns. The compass/blueprint source lives in
# macos/assets/AppIcon/make-icon.swift.
ICON_DST="${APP_DIR}/Contents/Resources/AppIcon.icns"
if command -v iconutil >/dev/null 2>&1 && command -v swift >/dev/null 2>&1 \
   && [[ -f "${ICON_GEN}" ]]; then
    ICONSET_TMP="${ICON_DIR}/AppIcon.iconset"
    echo "==> Generating app icon from ${ICON_GEN##*/}"
    rm -rf "${ICONSET_TMP}"
    if swift "${ICON_GEN}" "${ICONSET_TMP}" >/dev/null \
       && iconutil -c icns "${ICONSET_TMP}" -o "${ICON_ICNS}"; then
        echo "    regenerated ${ICON_ICNS##*/} from source"
    else
        echo "warning: icon regeneration failed; using committed ${ICON_ICNS##*/}" >&2
    fi
fi
if [[ -f "${ICON_ICNS}" ]]; then
    cp "${ICON_ICNS}" "${ICON_DST}"
    echo "    bundled app icon: Contents/Resources/AppIcon.icns"
else
    echo "warning: no app icon at ${ICON_ICNS}; the bundle will use the generic icon" >&2
fi

echo "==> Ad-hoc signing"
codesign --force --sign - "${APP_DIR}"

echo "==> Verifying signature"
codesign -dv "${APP_DIR}" 2>&1 | sed 's/^/    /'

# --- Optional Developer ID signing + notarization ----------------------------
# DEFAULT BEHAVIOR IS UNCHANGED: the .app above is ad-hoc signed. Setting
# SIGN_RELEASE=1 additionally hands the bundle to sign-and-notarize.sh, which
# re-signs with a Developer ID identity + hardened runtime and (if credentials
# are present) notarizes + staples. That script itself gracefully falls back to
# ad-hoc signing when no Developer ID credentials are set, so this hook never
# breaks a credential-less build. See macos/docs/ci-and-release.md.
if [[ "${SIGN_RELEASE:-0}" == "1" ]]; then
    echo "==> SIGN_RELEASE=1: invoking sign-and-notarize.sh"
    bash "${SCRIPT_DIR}/sign-and-notarize.sh" "${APP_DIR}"
fi

echo "==> Done: ${APP_DIR}"
echo "    executable: ${APP_DIR}/Contents/MacOS/${EXE_NAME}"
