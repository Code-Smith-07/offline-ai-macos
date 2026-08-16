#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:h}"
DIST_DIR="$REPO_DIR/dist-macos"
APP="$DIST_DIR/Offline AI.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
MACOS="$CONTENTS/MacOS"
PYTHON_SOURCE="${OFFLINE_AI_PYTHON_SOURCE:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python}"
PYTHON="$PYTHON_SOURCE/bin/python3.12"
SITE_PACKAGES="$RESOURCES/python/lib/python3.12/site-packages"
WHEEL_DIR="$DIST_DIR/wheels"
DMG_ROOT="$DIST_DIR/dmg-root"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")"
DMG="$DIST_DIR/Offline-AI-${APP_VERSION}-arm64.dmg"

if [[ ! -x "$PYTHON" ]]; then
  echo "Python 3.12 runtime not found at $PYTHON" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
for old in "$APP" "$DMG_ROOT" "$DMG"; do
  [[ ! -e "$old" ]] || mv "$old" "$old.previous.$(date +%s)"
done
mkdir -p "$MACOS" "$RESOURCES" "$SITE_PACKAGES"

echo "Preparing bundled Kokoro voice assets"
"$SCRIPT_DIR/download_kokoro_assets.sh"

echo "Compiling native macOS shell"
mkdir -p "$DIST_DIR/module-cache"
CLANG_MODULE_CACHE_PATH="$DIST_DIR/module-cache" SWIFT_MODULE_CACHE_PATH="$DIST_DIR/module-cache" /usr/bin/swiftc \
  -O -target arm64-apple-macos13.0 \
  -framework Cocoa -framework WebKit -framework AVFoundation \
  "$SCRIPT_DIR/OfflineAIApp.swift" \
  -o "$MACOS/OfflineAI"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$SCRIPT_DIR/start_backend.sh" "$RESOURCES/start_backend.sh"
cp "$SCRIPT_DIR/import_hugging_face_models.sh" "$RESOURCES/import_hugging_face_models.sh"
cp "$REPO_DIR/LICENSE" "$RESOURCES/OPEN_WEBUI_LICENSE"
cp "$REPO_DIR/LICENSE_NOTICE" "$RESOURCES/OPEN_WEBUI_LICENSE_NOTICE"
cp "$REPO_DIR/LICENSE_HISTORY" "$RESOURCES/OPEN_WEBUI_LICENSE_HISTORY"
cp "$REPO_DIR/NOTICE" "$RESOURCES/OFFLINE_AI_NOTICE"
cp "$REPO_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
mkdir -p "$RESOURCES/LICENSES"
cp "$REPO_DIR/LICENSES/OFFLINE_AI_ADDITIONS.md" "$RESOURCES/LICENSES/OFFLINE_AI_ADDITIONS.md"
cp "$REPO_DIR/LICENSES/MIT.txt" "$RESOURCES/LICENSES/MIT.txt"
cp "$REPO_DIR/LICENSES/Apache-2.0.txt" "$RESOURCES/LICENSES/Apache-2.0.txt"
chmod 755 "$MACOS/OfflineAI" "$RESOURCES/start_backend.sh" "$RESOURCES/import_hugging_face_models.sh"

echo "Bundling portable Python 3.12"
/usr/bin/rsync -a \
  --exclude='lib/python3.12/site-packages/***' \
  --exclude='lib/pkgconfig/***' \
  --exclude='share/man/***' \
  "$PYTHON_SOURCE/" "$RESOURCES/python/"
mkdir -p "$SITE_PACKAGES"

echo "Installing Open WebUI and backend dependencies"
mkdir -p "$WHEEL_DIR" "$DIST_DIR/build-tools"
cp "$SCRIPT_DIR/npm_build_stub.sh" "$DIST_DIR/build-tools/npm"
chmod 755 "$DIST_DIR/build-tools/npm"
PATH="$DIST_DIR/build-tools:/usr/bin:/bin:/usr/sbin:/sbin" \
  PIP_CACHE_DIR="$REPO_DIR/.pip-cache" "$PYTHON" -m pip wheel \
  --no-deps \
  --wheel-dir "$WHEEL_DIR" \
  "$REPO_DIR"
OPEN_WEBUI_WHEELS=("$WHEEL_DIR"/open_webui-*.whl)
if [[ ${#OPEN_WEBUI_WHEELS[@]} -ne 1 ]]; then
  echo "Expected one Open WebUI wheel, found ${#OPEN_WEBUI_WHEELS[@]}" >&2
  exit 1
fi
PIP_CACHE_DIR="$REPO_DIR/.pip-cache" "$PYTHON" -m pip install \
  --target "$SITE_PACKAGES" \
  --no-compile \
  --upgrade \
  "${OPEN_WEBUI_WHEELS[1]}"

echo "Creating Open WebUI icon"
ICONSET="$DIST_DIR/AppIcon.iconset"
[[ ! -e "$ICONSET" ]] || mv "$ICONSET" "$ICONSET.previous.$(date +%s)"
mkdir -p "$ICONSET"
ICON_SOURCE="$REPO_DIR/static/static/web-app-manifest-512x512.png"
for spec in '16 16x16' '32 16x16@2x' '32 32x32' '64 32x32@2x' '128 128x128' '256 128x128@2x' '256 256x256' '512 256x256@2x' '512 512x512' '1024 512x512@2x'; do
  size="${spec%% *}"
  label="${spec#* }"
  /usr/bin/sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${label}.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
cp "$ICON_SOURCE" "$RESOURCES/AppIcon.png"

echo "Removing packaging-only metadata"
find "$SITE_PACKAGES" -type d \( -name '__pycache__' -o -name 'tests' -o -name 'test' \) -prune -exec /bin/rm -rf {} + 2>/dev/null || true

echo "Signing app"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "Creating DMG"
mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP" "$DMG_ROOT/Offline AI.app"
/bin/ln -s /Applications "$DMG_ROOT/Applications"
/usr/bin/hdiutil create -volname "Offline AI" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

echo "$APP"
echo "$DMG"
