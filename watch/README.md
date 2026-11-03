# watch — a read-only recorder for Universal Control drops

`tools/` keeps a Sidecar session alive with the lid closed. This folder does not
change any of that: it **only records**, so that the cause of a Universal Control (UC)
drop can be read from data instead of guessed. Nothing here configures displays,
talks to SidecarCore or touches the network, and nothing under `tools/` is modified
or required except `tools/logs/sidecar.log`, which is read.

## Why

On 2026-11-02 every `Peer appears missing` logged by UniversalControl fell within a
few seconds of a `sidecar up`/`down` (connect or disconnect), with two exceptions
(22:16:14 and 22:28:45). Whether the lid transitions and the display arrangement play
a role as well is still open. The watcher collects the evidence during normal use —
including the iPad moving to another Mac as its Sidecar.

## Install

```bash
./install.sh            # ~/sidecar-watch + LaunchAgent local.sidecar.watch
./install.sh --no-load  # install only
./install.sh --uninstall
```

Requires `swiftc` and `/usr/bin/jq`. No sudo. Separate from `local.sidecar.vdisp`.
`install.sh` copies everything to `~/sidecar-watch`, so the running copy does not
depend on this checkout.

## What it records

`~/sidecar-watch/logs/timeline.log`, one tab-separated line per event:
`timestamp  TAG  KIND  message`.

| tag | source | kinds |
|---|---|---|
| `UC` | unified log, UniversalControl | `DROP` (Peer appears missing), `NETERR`, `ACTIVE` / `IDLE` (UC in use or not) |
| `SC` | unified log, `com.apple.sidecar` | `CONNECT-REQ` / `DISCONNECT-REQ` (with `by=` the requesting process), `CONNECTED`, `CLOSED`, `SLEEP-DISCONNECT`, `RECONNECTING`, `HW-CHANGED`, `ERROR`, … |
| `TOOL` | `tools/logs/sidecar.log` | `CONNECT`, `DISCONNECT`, `CONNECTED`, `LAYOUT`, `ERROR`, `WARN`, `INFO` |
| `LID` | `ioreg` every 10 s | `open` / `closed` |
| `DISP` | `bin/snap` every 10 s | the display set, e.g. `virtual#17*main sidecar#21>17` (`*main`, `>N` mirrors N) |
| `NET` | CoreWLAN + `ifconfig awdl0` | channel, band, AWDL status |
| `PWR`, `VDISP` | `pmset`, `pgrep` | power source, vdisp pids |
| `HB` | every 5 min | full snapshot, including RSSI |

State lines are written only when something changes. The file rotates at 20 MB to
`timeline.1.log`.

## Analyse

```bash
~/sidecar-watch/bin/uc-analyze             # the recording
~/sidecar-watch/bin/uc-analyze --verbose   # plus every event in each window
~/sidecar-watch/bin/uc-analyze --from-system '2026-11-02 22:00:00' '2026-11-02 23:30:00'
```

Every drop (drops ≤ 5 s apart count as one incident) is attributed to the
highest-priority event in the 15 s before it (2 s after, for lines logged late):
`tool-connect`/`tool-disconnect` › `sidecar-manual-*` (Control Center or another
process) › `lid-open`/`lid-closed` › `display-sleep` › `sidecar-closed` (the session
ended without a request from here: e.g. the iPad taken by another Mac) ›
`sidecar-reconnecting` › `vdisp-changed` › `display-topology` › `wifi/awdl` › `power`
› `spontaneous`. The summary counts causes, lid states and Sidecar sessions.

`--from-system` rebuilds a timeline from the unified log and `sidecar.log` for any
past window; lid, display and Wi-Fi changes exist only in a recording.

## Files

```
uc-watch                      the recorder (bash 3.2, runs under launchd)
uc-analyze                    the classifier (read-only)
src/snap.swift                one snapshot of displays (main, mirror, origin) and Wi-Fi
lib/predicate                 unified-log predicate, shared by both scripts
lib/events.jq                 log ndjson -> timeline lines, shared by both scripts
lib/toolline.awk              sidecar.log -> timeline lines, shared by both scripts
daemon/local.sidecar.watch.plist.in
install.sh
```
