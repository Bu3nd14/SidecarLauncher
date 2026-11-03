#!/usr/bin/env bash
# install.sh — copy the watcher to a durable place and load its LaunchAgent.
#
#   ./install.sh              install into ~/sidecar-watch, load local.sidecar.watch
#   ./install.sh --no-load    install only (run ~/sidecar-watch/bin/uc-watch by hand)
#   ./install.sh --uninstall  unload the agent and remove its plist (logs are kept)
#
# Variables: WATCH_HOME (default ~/sidecar-watch), TOOLS (default ~/SidecarLauncher/tools,
# only tools/logs/sidecar.log is read). Touches nothing under tools/ and does not
# interact with local.sidecar.vdisp. No sudo.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_HOME="${WATCH_HOME:-$HOME/sidecar-watch}"
TOOLS="${TOOLS:-$HOME/SidecarLauncher/tools}"
LABEL="local.sidecar.watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

die() { printf 'install: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  "") LOAD=1 ;;
  --no-load) LOAD=0 ;;
  --uninstall)
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "unloaded $LABEL, removed $PLIST (logs kept in $WATCH_HOME/logs)"
    exit 0 ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac

command -v swiftc >/dev/null || die "swiftc not found (Xcode command line tools)"
[ -x /usr/bin/jq ] || die "/usr/bin/jq not found"
case "$WATCH_HOME$TOOLS" in *'#'*|*'&'*|*'\'*) die "path contains a character sed would mangle" ;; esac
[ -f "$TOOLS/logs/sidecar.log" ] || echo "note: $TOOLS/logs/sidecar.log not found yet; the watcher waits for it"

mkdir -p "$WATCH_HOME/bin" "$WATCH_HOME/lib" "$WATCH_HOME/logs"

tmp="$WATCH_HOME/bin/.snap.building"
swiftc -O -o "$tmp" "$ROOT/src/snap.swift"
mv -f "$tmp" "$WATCH_HOME/bin/snap"
install -m 755 "$ROOT/uc-watch" "$ROOT/uc-analyze" "$WATCH_HOME/bin/"
install -m 644 "$ROOT/lib/events.jq" "$ROOT/lib/toolline.awk" "$ROOT/lib/predicate" "$WATCH_HOME/lib/"
echo "installed: $WATCH_HOME/bin/{uc-watch,uc-analyze,snap}, $WATCH_HOME/lib"

[ "$LOAD" -eq 1 ] || exit 0

mkdir -p "$(dirname "$PLIST")"
staged="$PLIST.$$"
trap 'rm -f "$staged"' EXIT
sed -e "s#@@HOME@@#$WATCH_HOME#g" -e "s#@@TOOLS@@#$TOOLS#g" "$ROOT/daemon/$LABEL.plist.in" >"$staged"
plutil -lint "$staged" >/dev/null || die "rendered plist is not valid"
mv -f "$staged" "$PLIST"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed (is a graphical session logged in?)"
sleep 2
state="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -n 1)"
echo "agent:     $LABEL ($DOMAIN) ${state:-unknown}"
echo "timeline:  $WATCH_HOME/logs/timeline.log"
echo "analyse:   $WATCH_HOME/bin/uc-analyze"
