# Universal Control drops — why yesterday and not today

Status: **hypothesis supported by logs**, 2026-11-03 09:30. Read-only analysis; nothing
under `tools/` was changed to produce it. Machine: MacBook Air M5 (Mac17,4), macOS 27.2;
iPad14,8 (IDS `5F628A77`); this Mac IDS `7461BC61`; another Mac in the UC group IDS
`A051E41E`.

## The question

On 2026-11-02 Universal Control (UC) kept dropping within minutes of closing the lid and
came back when the lid was reopened. On 2026-11-03, after changes made overnight, it does
not drop. What actually changed?

## Short answer

The symptom had **four different causes over the day**, and the overnight layout change
(f56b25c, virtual display main + Sidecar mirroring it) is **not** what made the
difference: in the evening, with the *old* layout, the lid was opened and closed six
times (22:57 → 23:24) with **zero** drops.

| period (2026-11-02) | cause of the drops | why it stopped |
|---|---|---|
| until ~13:54 | **no virtual display**: closing the lid sets `DesktopMode with AC: 0`, Sidecar closes its session, UC drops; reopening restores it (12:31:02 lid closed → Sidecar CLOSED → UC drop 12:32). This is literally "drops when I close the lid, back when I open it". | `vdisp` (a75e3c2, 13:54) keeps a non-built-in display alive, so DesktopMode stays 1 |
| afternoon–evening | **our own churn**: every `sidecar up`/`down` (and the retry loops of earlier tool versions: connect → CONNECTED → CLOSED, dozens of times at 14:18, 19:10, 19:27, 19:35, 19:48) restarts the iPad's Sidecar session, and UC loses the iPad as a peer | today: one `up`, no loops (3846cf5 cut the reconnects) |
| afternoon–evening | **display sleep**: after 10 idle minutes (`pmset displaysleep 10`) Sidecar logs `Display Sleep: Disconnecting` and closes the session → UC drop. 8 times: 13:43, 14:40, 15:08, 16:36, 17:40, 20:47, 21:49, 23:30 | **not fixed** — this morning UC was in use and held `PreventUserIdleDisplaySleep`; see "Still open" |
| afternoon–evening | **Sidecar reconnecting by itself** (`CLOSED → Reconnecting → CONNECTED`, no request): 13:14, 13:15, 18:03, 20:06, 21:20, 21:28 ×2, 22:23, 22:44, 23:33 | unclear: none since the reboot (21:35) + night sleep + clean display state; 614 Sidecar errors yesterday (mostly `-200 Reconnect Failed`, `-501` from zombie displays) |

What did **not** matter, checked against the logs: power (AC all day), system sleep
(`disablesleep 1` during the day via `local.coffee.tick`), Wi-Fi channel (drops on ch 40
yesterday, stable on ch 40 today), the reboot alone (drops continued after 21:35).

## The mechanism: UC's peer is the iPad

UniversalControl tracks the iPad itself (`universalcontrol:LINK IDS 5F628A77: Device
Changed`). Whenever the iPad's Sidecar role changes — this Mac connects or disconnects,
the session sleeps or reconnects, **or another Mac takes the iPad** — UC logs
`Peer appears missing, invalidating` and `kNetworkErr -> kConnectionErr (Read EOF)`
within 0–3 s. Confirmed live today during a switch to the work Mac:

| time | event | UC drop |
|---|---|---|
| 09:04:12 | `sidecar down` | 09:04:27 |
| 09:04:40–59 | iPad taken by the work Mac (17 `Device Changed` in 22 s; at rest ≤ 5 per 20 s) | 09:04:52 |
| 09:05:16 | `sidecar up` → connected 09:05:18 | 09:05:19 |
| after 09:05:21 | — | none |

So **every switch of the iPad between Macs costs one UC drop per transition**: that is
how the OS behaves and cannot be avoided, only not multiplied.

## Evidence, and how to reproduce it

- UC drops: unified log, `process == "UniversalControl"`, message `Peer appears missing`.
  The `RPStreamSession Invalidated ... EVNT` count is **not** a drop signal (UC closes
  idle streams normally).
- Sidecar sessions: `subsystem == "com.apple.sidecar"`, messages
  `=== Sidecar Connect|Disconnect|Connected IDS ...`, `=== SideCar Session didClose ===`,
  `=== Display Sleep: Disconnecting ===`, `=== Sidecar Reconnecting to ...`.
- Lid: `process == "ControlCenter"`, `Clamshell state changed to open|closed`;
  DesktopMode: `process == "powerd"`, `DesktopMode with AC: 0|1`.
- Tool actions: `tools/logs/sidecar.log`.
- Classifier: branch `uc-watch`, `watch/uc-analyze --from-system 'START' 'END'`
  attributes each drop to the event in the 15 s before it. Over 2026-11-02 12:00–21:36:
  37 incidents → 26 Sidecar connect/disconnect, 3 Sidecar closed by itself, 1 display
  sleep, 1 iPad burst, 3 weak peer re-advertising, 3 unexplained.
- Recorder: LaunchAgent `local.sidecar.watch` writes `~/sidecar-watch/logs/timeline.log`
  continuously (lid, display set/main/mirror, Wi-Fi/AWDL, power, peers, Sidecar, tools).
  `~/sidecar-watch/bin/uc-analyze --verbose` reads it.

## Still open (predictions to check with the recorder)

1. **Display sleep will still kill the session.** If the Mac stays idle for 10 minutes
   with UC not in use (pointer on another device), expect `SC SLEEP-DISCONNECT` followed
   by `UC DROP`. Candidate fix for later: keep the displays awake while a Sidecar session
   is up (e.g. a `caffeinate -d` owned by the session, or `pmset -c displaysleep 0`).
2. **Spontaneous Sidecar reconnects.** If they come back, the recorder will show whether
   they line up with display-topology changes, AWDL/Wi-Fi changes or zombie displays.
3. **The layout.** No evidence yet that "virtual main + Sidecar mirror" beats the old
   layout for UC; the README figure "~4 min vs ~1 min" was measured with `up`/`down` inside
   the window and should be re-measured.

## Implications for the tools (to do together, not yet done)

- `up` should be idempotent: if the session is healthy, do not disconnect/reconnect —
  each reconnect is one guaranteed UC drop.
- Retry loops must not reconnect a session that just connected and closed (yesterday's
  loops produced dozens of sessions per minute).
- Consider keeping displays awake for the life of the session ("Still open" 1).
- `setmode`, `dispmode` and `mirror` still enumerate *active* displays and miss a mirrored
  Sidecar (7cbf7ee fixed only `arrange` and `doctor`).
