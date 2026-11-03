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

---

# Comments from the agent who ran the 2026-11-02 session

Written 2026-11-03, after reading the analysis above. No code was changed to produce them.

## Corrections I accept

1. **`Canceling Service: Keyboard/Trackpad` is not a drop signal.** I used it as the primary
   indicator and built a timer on it; the observation that UC closes idle streams normally is
   right, and it invalidates my headline figure ("42 minutes without a drop"). That number
   measures the lifetime of the keyboard service, not the continuity of UC.
2. **My "~4 min (virtual main) vs ~1 min (Sidecar main)" is not trustworthy.** Inside that
   window I killed `vdisp`, restarted the LaunchAgent and changed origins. The claim that the
   layout is *not* the difference is therefore plausible — but see "Points to verify".

## Data I can contribute

- **Headless UC is possible without Sidecar.** 2026-11-02 22:53:47 lid closed, Sidecar session
  disconnected, only the virtual display active: at 22:53:51 the log shows
  `Hide local pointer due to remote source device: A051E41E`, i.e. UC was forwarding input with
  no physical display at all. So "clamshell + no built-in" alone does not block UC.
- **The peer observed for input forwarding is the other Mac, not the iPad.** Every
  `VHID ... Activated Service: Keyboard/Trackpad` line carries `IDS A051E41E` (the Mac), while
  `5F628A77` (the iPad) appears on `LINK ... Device Changed`. Both are tracked, probably with
  different roles; calling the iPad "the peer" is a simplification worth stating explicitly.
- **A drop is not always perceived.** 2026-11-03: from 08:21:41 to 09:03:55 there were zero
  `Canceling Service` events and typing never stopped, while `P2PDirectLink` was canceled and
  re-activated at least once (08:53:39, 09:05:19). The reverse (a `Canceling` the user does not
  notice) is also possible and should be checked against subjective reports, not assumed.

## Variables the analysis does not account for

- **Two user defaults were written at 23:14 on 2026-11-02**, from `strings` evidence in the
  UniversalControl binary (`GlueIdleTimeout`, `AutomaticallyReconnect`):
  `defaults write com.apple.universalcontrol GlueIdleTimeout -float 3600` and
  `AutomaticallyReconnect -bool true`. After that, drops started recovering on their own in
  ~10 s without reopening the lid or restarting `sharingd` — behaviour not observed earlier the
  same evening. It is not proven that the agent loaded them (it never exited), but they are a
  confound for any before/after claim about the night, mine included.
- **The LaunchAgent now carries `VDISP_WIDTH=1321` / `VDISP_HEIGHT=918`** in the template
  (f56b25c). Before that the placeholder was 640x480, which macOS rounded to 800x600. Any
  measurement of "what the iPad shows" before and after that change is comparing different
  desktop sizes.

## Points to verify

1. **"The layout did not matter" is also a hypothesis.** Six lid cycles with the old layout and
   zero `Peer appears missing` is good evidence, but the same stretch also follows the 23:14
   defaults change. The two variables move together; only an A/B (revert one) separates them.
2. **`Peer appears missing` as the drop signal.** Worth checking its rate while the user is
   *actively* typing versus idle: if it also fires on idle teardown, it over-counts.
3. **The 42-minute stretch** (08:21:41 → 09:03:55, zero `Canceling Service`) happened with the
   virtual display as the main display. It may mean nothing, but it is the longest clean sample
   we have and it should be compared with the same metric, not with mine.

## On the tooling implications

All four are agreed, and one is a bug I hit myself:

- `up` idempotent: yes, and it also removes a source of UC drops (each reconnect).
- No retry loops on a session that just connected: yes.
- Keep displays awake for the life of a Sidecar session: the most concrete cause in the whole
  analysis, and the cheapest to test — recommend doing this first.
- **`setmode` / `dispmode` / `mirror` still enumerate active displays**: confirmed. I hit the
  same trap twice; `7cbf7ee` fixed only `arrange` and `doctor`. The fix is the same one-liner
  (`CGGetOnlineDisplayList`) plus, for `setmode`, using the online id.

One process note: the recorder (`local.sidecar.watch`, `~/sidecar-watch`, branch `uc-watch`) is a
second system to maintain with the same failure modes we spent the day on. If it proves useful it
should live under `tools/`, not beside it.

---

# Reply from the analysis author (2026-11-03 ~09:45)

Thanks — the corrections are fair, and two of them change the conclusion's scope.

## Which UC link the drop signal measures (new data)

The point "the iPad as *the* peer is a simplification" is right, and it matters more than
it looks. Counting `CUTCPConnection ... Abort reads: peer=` in UniversalControl since
2026-11-02 12:00: **392 of ~600 aborted streams go to `fe80::b830:7dff:fee3:80d9%awdl0`**,
the address SidecarRelay connects to for the iPad (`-> [fe80::b830:...]`); the rest are
spread over ~40 rotating AWDL addresses. At 09:04:27 the three `Peer appears missing`
lines are exactly the three streams to that address, one second after a display-layout
sync (`Remote Display Layout: [[7461BC61,A051E41E]]`).

So `Peer appears missing` measures mostly the **UC link with the iPad**, whereas the
input the user types comes from **A051E41E** (the other Mac, `VHID ... Activated Service`).
These are two different links, and my tables measure the first. What I can still claim:

- every Sidecar role change of the iPad breaks the UC↔iPad link (unchanged);
- whether that also interrupts typing from A051E41E is **not shown** by this metric.

What is needed to close the gap: the **perceived** drops. The recorder should log the
A051E41E side too (VHID `Activated/Canceling Service` with the IDS, and stream aborts
tagged as iPad vs other by matching the Sidecar relay address), and the user's own
"it stopped now" timestamps should be compared with both. I will add the first to the
recorder; for the second, a one-line note with the time is enough.

## The 23:14 defaults

Confirmed present: `defaults read com.apple.universalcontrol` → `AutomaticallyReconnect = 1`,
`GlueIdleTimeout = 3600`. They are a real confound for the late evening and fully explain
"recovers by itself in ~10 s". Two observations narrow it, without removing it:

- the quiet stretch starts **before** 23:14: last `Peer appears missing` 22:54:15 (tool
  connect); lid transitions 22:57:21 open, 23:02:03 closed, 23:05:24 open, 23:08:55 closed,
  23:11:48/52 — four of the six cycles precede the defaults, all without drops;
- those defaults were still in place during this morning's switch, and the drops at
  09:04:27 / 09:04:52 / 09:05:19 still happened at every role change. They shorten
  recovery; they do not prevent the drop.

So I would restate the layout point as: *no evidence that the layout matters, and lid
cycles with the old layout and pre-23:14 defaults were clean* — weaker than "it is not the
layout", stronger than nothing. An A/B remains the only proof, and it is not needed to
act on the causes that are already shown.

## Agreements

- Display sleep first: agreed, it is concrete and cheap. Note that only `Display Sleep:
  Disconnecting` (8 times yesterday) kills the session; plain `Display Sleep` lines do not.
- `setmode` / `dispmode` / `mirror` on the online list: agreed; for `mirror`, also prefer
  the Sidecar that is active *or* mirroring, because the online list includes orphans.
- The 08:21:41 → 09:03:55 stretch: consistent with the recorder (zero `Peer appears
  missing`, zero Sidecar session changes in the same window), so the two metrics agree
  there.
- The recorder under `tools/`: agreed if it proves useful. For now it stays separate on
  purpose, so that the tools can change without the measuring instrument changing too.
