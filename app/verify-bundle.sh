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
struttura del bundle, Info.plist (0.3.0/4), TOOLS_VERSION, lipo -archs=arm64 su
eseguibile e 5 tool, firma ad-hoc. Con --no-build verifica app/build.
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
for entry in AppIcon:AppIcon.icns AppIconSwitch:AppIconSwitch.icns; do
  icon_name="${entry%%:*}"
  icon_file="${entry##*:}"
  icon_path="$BUNDLE/Contents/Resources/$icon_file"
  [ -s "$icon_path" ] || die "icona assente o vuota: $icon_path"
  file "$icon_path" | grep -q "Mac OS X icon" || die "$icon_file non ha il magic Mac OS X icon"
  iconutil -c iconset "$icon_path" -o "$VERIFY_TMP/$icon_name.iconset"
  for name in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
              icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
              icon_512x512.png icon_512x512@2x.png; do
    [ -s "$VERIFY_TMP/$icon_name.iconset/$name" ] || die "icona $icon_file: taglia mancante $name"
  done
done
PLIST_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$BUNDLE/Contents/Info.plist")"
[ "$PLIST_ICON" = "AppIcon" ] || die "CFBundleIconFile ($PLIST_ICON) != AppIcon"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
  die "CFBundleIconName non deve essere presente (nessun asset catalog)"
fi
ok "entrambe le icone presenti/valide, 10 taglie ciascuna, CFBundleIconFile=AppIcon"

[ -f "$BUNDLE/Contents/Resources/LICENSE" ] || die "LICENSE assente in Contents/Resources"
ok "LICENSE in Contents/Resources"

SIDECAR_ICON_WORKDIR="$VERIFY_TMP/gen" swift "$APP_DIR/make-icon.swift" "$VERIFY_TMP/second.icns"
iconutil -c iconset "$VERIFY_TMP/second.icns" -o "$VERIFY_TMP/Second.iconset"
swift "$APP_DIR/make-icon.swift" --rgba-1024 "$VERIFY_TMP/AppIcon.iconset/icon_512x512@2x.png" "$VERIFY_TMP/first.raw"
swift "$APP_DIR/make-icon.swift" --rgba-1024 "$VERIFY_TMP/Second.iconset/icon_512x512@2x.png" "$VERIFY_TMP/second.raw"
H1="$(shasum -a 256 "$VERIFY_TMP/first.raw" | awk '{print $1}')"
H2="$(shasum -a 256 "$VERIFY_TMP/second.raw" | awk '{print $1}')"
[ "$H1" = "$H2" ] || die "icona non riproducibile: $H1 != $H2"
ok "icona riproducibile (SHA-256 pixel RGBA 1024: $H1)"

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
[ "$PLIST_VERSION" = "0.3.0" ] || die "CFBundleShortVersionString ($PLIST_VERSION) != 0.3.0"
[ "$PLIST_BUILD" = "4" ] || die "CFBundleVersion ($PLIST_BUILD) != 4"
if git -C "$REPO_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  EXPECTED="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  [ "$VERSION" = "$EXPECTED" ] || die "TOOLS_VERSION ($VERSION) != git HEAD ($EXPECTED)"
fi
ok "TOOLS_VERSION separato ($VERSION); bundle 0.3.0 (4)"

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
