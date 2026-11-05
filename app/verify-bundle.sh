#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd -P "$APP_DIR/.." && pwd)"
TOOLS=(SidecarLauncher connected dispid mirror arrange)

die() { printf 'verify-bundle: %s\n' "$*" >&2; exit 1; }
ok() { printf '  OK  %s\n' "$*"; }

MODE="build"
case "${1:-}" in
  "") ;;
  --no-build) MODE="no-build" ;;
  -h|--help)
    cat <<EOF
usage: ./verify-bundle.sh [--no-build]

Esegue app/build.sh in una directory temporanea (K1) e verifica:
struttura del bundle, Info.plist (0.4.0/5), TOOLS_VERSION, lipo -archs=arm64 su
eseguibile e 5 tool, una sola icona AppIcon.icns, firma ad-hoc. Con --no-build
verifica app/build e ricostruisce IconGen prima dell'uso.
EOF
    exit 0
    ;;
  *) die "argomento sconosciuto: $1" ;;
esac

VERIFY_TMP=""
cleanup() {
  [ -n "$OUTPUT" ] && [ "$MODE" = "build" ] && rm -rf "$OUTPUT"
  [ -n "$VERIFY_TMP" ] && rm -rf "$VERIFY_TMP"
  return 0
}
trap cleanup EXIT

if [ "$MODE" = "build" ]; then
  OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-switch-verify.XXXXXX")"
  printf 'verify-bundle: build in %s\n' "$OUTPUT"
  SIDECAR_SWITCH_OUTPUT="$OUTPUT" "$APP_DIR/build.sh"
else
  OUTPUT="$APP_DIR/build"
fi

BUNDLE="$OUTPUT/SidecarSwitch.app"
[ -d "$BUNDLE" ] || die "bundle assente: $BUNDLE"
ok "bundle presente"

[ -x "$BUNDLE/Contents/MacOS/SidecarSwitch" ] || die "eseguibile assente"
ok "Contents/MacOS/SidecarSwitch"

[ -f "$BUNDLE/Contents/Info.plist" ] || die "Info.plist assente"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
ok "Info.plist valido"

VERIFY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-switch-icon.XXXXXX")"
swift build -c release --package-path "$APP_DIR" --product IconGen >/dev/null
BIN_PATH="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"
ICONGEN="$BIN_PATH/IconGen"
[ -x "$ICONGEN" ] || die "IconGen non prodotto: $ICONGEN"

ICNS_COUNT="$(find "$BUNDLE/Contents/Resources" -maxdepth 1 -name '*.icns' | wc -l | tr -d ' ')"
[ "$ICNS_COUNT" = "1" ] || die "attesa una sola .icns, trovate $ICNS_COUNT"
ICON_PATH="$BUNDLE/Contents/Resources/AppIcon.icns"
[ -s "$ICON_PATH" ] || die "icona assente o vuota: $ICON_PATH"
file "$ICON_PATH" | grep -q "Mac OS X icon" || die "AppIcon.icns non ha il magic Mac OS X icon"
iconutil -c iconset "$ICON_PATH" -o "$VERIFY_TMP/AppIcon.iconset"
for name in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
            icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
            icon_512x512.png icon_512x512@2x.png; do
  [ -s "$VERIFY_TMP/AppIcon.iconset/$name" ] || die "icona AppIcon.icns: taglia mancante $name"
done
PLIST_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$BUNDLE/Contents/Info.plist")"
[ "$PLIST_ICON" = "AppIcon" ] || die "CFBundleIconFile ($PLIST_ICON) != AppIcon"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
  die "CFBundleIconName non deve essere presente (nessun asset catalog)"
fi
ok "una sola icona AppIcon.icns valida, 10 taglie, CFBundleIconFile=AppIcon"

[ -f "$BUNDLE/Contents/Resources/LICENSE" ] || die "LICENSE assente in Contents/Resources"
ok "LICENSE in Contents/Resources"

SIDECAR_ICON_WORKDIR="$VERIFY_TMP/gen" "$ICONGEN" "$VERIFY_TMP/fresh.icns"
iconutil -c iconset "$VERIFY_TMP/fresh.icns" -o "$VERIFY_TMP/Fresh.iconset"
"$ICONGEN" --rgba-1024 "$VERIFY_TMP/AppIcon.iconset/icon_512x512@2x.png" "$VERIFY_TMP/bundle.raw"
"$ICONGEN" --rgba-1024 "$VERIFY_TMP/Fresh.iconset/icon_512x512@2x.png" "$VERIFY_TMP/fresh.raw"
H1="$(shasum -a 256 "$VERIFY_TMP/bundle.raw" | awk '{print $1}')"
H2="$(shasum -a 256 "$VERIFY_TMP/fresh.raw" | awk '{print $1}')"
[ "$H1" = "$H2" ] || die "icona non riproducibile: bundle $H1 != IconGen fresco $H2"
ok "icona del bundle identica a IconGen fresco (SHA-256 pixel RGBA 1024: $H1)"

for tool in "${TOOLS[@]}"; do
  [ -x "$BUNDLE/Contents/Resources/$tool" ] || die "tool assente o non eseguibile: $tool"
done
ok "5 tool presenti ed eseguibili"

[ -f "$BUNDLE/Contents/Resources/VERSION" ] || die "VERSION assente"

VERSION="$(tr -d '[:space:]' < "$BUNDLE/Contents/Resources/TOOLS_VERSION")"
[ -n "$VERSION" ] || die "TOOLS_VERSION vuota"
RESOURCES_VERSION="$(tr -d '[:space:]' < "$BUNDLE/Contents/Resources/VERSION")"
[ "$VERSION" = "$RESOURCES_VERSION" ] || die "VERSION ($RESOURCES_VERSION) != TOOLS_VERSION ($VERSION)"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist")"
[ "$PLIST_VERSION" = "0.4.0" ] || die "CFBundleShortVersionString ($PLIST_VERSION) != 0.4.0"
[ "$PLIST_BUILD" = "5" ] || die "CFBundleVersion ($PLIST_BUILD) != 5"
if git -C "$REPO_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  EXPECTED="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  [ "$VERSION" = "$EXPECTED" ] || die "TOOLS_VERSION ($VERSION) != git HEAD ($EXPECTED)"
fi
ok "TOOLS_VERSION separato ($VERSION); bundle 0.4.0 (5)"

check_arch() {
  local path="$1" label="$2" archs
  archs="$(lipo -archs "$path" 2>/dev/null)" || die "lipo fallito su $label"
  case " $archs " in
    *" arm64 "*) ok "$label: $archs" ;;
    *) die "$label non arm64: $archs" ;;
  esac
}
check_arch "$BUNDLE/Contents/MacOS/SidecarSwitch" "SidecarSwitch"
for tool in "${TOOLS[@]}"; do
  check_arch "$BUNDLE/Contents/Resources/$tool" "$tool"
done

codesign --verify --strict "$BUNDLE" >/dev/null 2>&1 || die "firma ad-hoc non valida"
ok "firma ad-hoc valida"

SIGN_INFO="$(codesign -dv "$BUNDLE" 2>&1 || true)"
printf '%s\n' "$SIGN_INFO" | grep -q "Signature=adhoc" || die "firma non ad-hoc"
ok "firma ad-hoc (sign -), nessun --deep"

printf 'verify-bundle: tutte le asserzioni K1 soddisfatte\n'
