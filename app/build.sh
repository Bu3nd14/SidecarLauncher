#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd -P "$APP_DIR/.." && pwd)"
TOOLS_BUILD="$REPO_DIR/tools/build.sh"
TOOLS_BIN="$REPO_DIR/tools/bin"
BUILD_DIR="${SIDECAR_SWITCH_OUTPUT:-$APP_DIR/build}"
BUNDLE_NAME="SidecarSwitch.app"
BUNDLE="$BUILD_DIR/$BUNDLE_NAME"
TOOLS=(SidecarLauncher connected dispid mirror arrange)
BUNDLE_SHORT_VERSION="0.4.1"
BUNDLE_VERSION="6"

die() { printf 'build: %s\n' "$*" >&2; exit 1; }

[ -f "$TOOLS_BUILD" ] || die "missing $TOOLS_BUILD"
mkdir -p "$BUILD_DIR"

for tool in "${TOOLS[@]}"; do
  [ -x "$TOOLS_BIN/$tool" ] || printf 'build: warning: %s non ancora compilato, tools/build.sh lo produrrà\n' "$TOOLS_BIN/$tool"
done

printf 'SidecarSwitch build\n'
printf '  data:    %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '  host:    %s\n' "$(hostname)"
printf '  uname:   %s (%s)\n' "$(uname -m)" "$(uname -s)"
printf '  repo:    %s\n' "$REPO_DIR"

printf '\n[1/6] tools/build.sh\n'
"$TOOLS_BUILD"

for tool in "${TOOLS[@]}"; do
  [ -x "$TOOLS_BIN/$tool" ] || die "$TOOLS_BIN/$tool non prodotto da tools/build.sh"
done

if git -C "$REPO_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  TOOLS_VERSION="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
else
  TOOLS_VERSION="unknown-$(date +%s)"
fi
printf '  TOOLS_VERSION: %s\n' "$TOOLS_VERSION"

printf '\n[2/6] swift build -c release\n'
swift build -c release --package-path "$APP_DIR"
BIN_PATH="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"
EXECUTABLE="$BIN_PATH/SidecarSwitch"
ICONGEN="$BIN_PATH/IconGen"
[ -x "$EXECUTABLE" ] || die "eseguibile non prodotto: $EXECUTABLE"
[ -x "$ICONGEN" ] || die "IconGen non prodotto: $ICONGEN"

printf '\n[3/6] icona programma (una sola .icns neutra)\n'
ICON_PATH="$BUILD_DIR/AppIcon.icns"
SIDECAR_ICON_WORKDIR="$BUILD_DIR" "$ICONGEN" "$ICON_PATH"
[ -s "$ICON_PATH" ] || die "icona non generata: $ICON_PATH"

printf '\n[4/6] assemblaggio bundle atomico\n'
STAGING="$BUILD_DIR/.$BUNDLE_NAME.staging.$$"
OLD="$BUILD_DIR/.$BUNDLE_NAME.old.$$"
rm -rf "$STAGING" "$OLD"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
trap 'rm -rf "$STAGING" "$OLD"' EXIT

cp "$EXECUTABLE" "$STAGING/Contents/MacOS/SidecarSwitch"
chmod 0755 "$STAGING/Contents/MacOS/SidecarSwitch"
strip -x "$STAGING/Contents/MacOS/SidecarSwitch"

for tool in "${TOOLS[@]}"; do
  cp "$TOOLS_BIN/$tool" "$STAGING/Contents/Resources/$tool"
  chmod 0755 "$STAGING/Contents/Resources/$tool"
done

cp "$ICON_PATH" "$STAGING/Contents/Resources/AppIcon.icns"
chmod 0644 "$STAGING/Contents/Resources/AppIcon.icns"
if [ -f "$REPO_DIR/LICENSE" ]; then
  cp "$REPO_DIR/LICENSE" "$STAGING/Contents/Resources/LICENSE"
  chmod 0644 "$STAGING/Contents/Resources/LICENSE"
fi

printf '%s\n' "$TOOLS_VERSION" > "$STAGING/Contents/Resources/TOOLS_VERSION"
printf '%s\n' "$TOOLS_VERSION" > "$STAGING/Contents/Resources/VERSION"

cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>it</string>
    <key>CFBundleExecutable</key>
    <string>SidecarSwitch</string>
    <key>CFBundleIdentifier</key>
    <string>local.sidecar.SidecarSwitch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SidecarSwitch</string>
    <key>CFBundleDisplayName</key>
    <string>SidecarSwitch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$STAGING/Contents/Info.plist" >/dev/null

printf '\n[5/6] verifica architettura (gate arm64)\n'
check_arch() {
  local path="$1" label="$2" archs
  archs="$(lipo -archs "$path" 2>/dev/null)" || die "lipo -archs fallito su $label"
  case " $archs " in
    *" arm64 "*) printf '  %-28s %s\n' "$label" "$archs" ;;
    *) die "$label non contiene arm64 (lipo -archs: $archs)" ;;
  esac
}
check_arch "$STAGING/Contents/MacOS/SidecarSwitch" "SidecarSwitch"
for tool in "${TOOLS[@]}"; do
  check_arch "$STAGING/Contents/Resources/$tool" "$tool"
done

printf '\n[6/6] swap + firma ad-hoc\n'
if [ -d "$BUNDLE" ]; then
  mv "$BUNDLE" "$OLD"
fi
if ! mv "$STAGING" "$BUNDLE"; then
  if [ -d "$OLD" ]; then
    mv "$OLD" "$BUNDLE"
  fi
  die "swap del bundle fallito"
fi
if [ -d "$OLD" ]; then
  rm -rf "$OLD"
fi
trap - EXIT

codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"

printf '\nBundle: %s\n' "$BUNDLE"
printf 'Bundle version: %s (%s)\n' "$BUNDLE_SHORT_VERSION" "$BUNDLE_VERSION"
printf 'TOOLS_VERSION: %s\n' "$TOOLS_VERSION"
printf 'Verifica: plutil OK, lipo arm64 OK, codesign ad-hoc OK\n'
