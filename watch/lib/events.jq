# events.jq — turns `log stream|show --style ndjson` records into timeline lines:
#   YYYY-MM-DDTHH:MM:SS <TAB> TAG <TAB> KIND <TAB> message
# Shared by uc-watch (live) and uc-analyze --from-system (past), so both classify
# the same way. Records that match nothing below are dropped.

def ts: (.timestamp // "") | .[0:19] | sub(" "; "T");
def msg: (.eventMessage // "") | gsub("[\t\n]"; " ") | .[0:300];
def proc: (.processImagePath // "") | split("/") | last;
def emit($tag; $kind): "\(ts)\t\($tag)\t\($kind)\t\(msg)";

# Input is read raw (jq -R): `log` prints a non-JSON banner line first.
fromjson? | objects
| select(.eventMessage != null)
| . as $r
| (msg) as $m
# A peer device (the iPad, another Mac) changing its advertised state, as seen by
# UniversalControl (uc) or SidecarRelay (sidecar). RSSI-only updates are filtered upstream.
| if ($m | test(": Device Changed")) then
    # A single change is weak evidence (peers re-advertise every minute or two);
    # uc-analyze looks at the rate per peer instead.
    (if proc == "UniversalControl" then "uc" else "sidecar" end) as $who
    | "\(ts)\tPEER\tCHANGED\t\($who) \($m | sub("^.*?IDS "; "IDS "))"
  elif proc == "UniversalControl" then
    if   ($m | contains("Peer appears missing"))            then emit("UC"; "DROP")
    elif ($m | contains("kNetworkErr -> kConnectionErr"))    then emit("UC"; "NETERR")
    elif ($m | contains("Take Display Sleep Assertion"))     then emit("UC"; "ACTIVE")
    elif ($m | contains("Release Display Sleep Assertion"))  then emit("UC"; "IDLE")
    else empty end
  elif ($r.subsystem // "") == "com.apple.sidecar" then
    if   ($m | test("^=== Sidecar Connect IDS"))             then emit("SC"; "CONNECT-REQ")
    elif ($m | test("^=== Sidecar Connected IDS"))           then emit("SC"; "CONNECTED")
    elif ($m | test("^=== Sidecar Disconnect IDS"))          then emit("SC"; "DISCONNECT-REQ")
    elif ($m | test("didClose"))                             then emit("SC"; "CLOSED")
    elif ($m | test("^=== Display Sleep: Disconnecting"))    then emit("SC"; "SLEEP-DISCONNECT")
    elif ($m | test("^=== Display Sleep"))                   then emit("SC"; "DISPLAY-SLEEP")
    elif ($m | test("^=== Display Wake"))                    then emit("SC"; "DISPLAY-WAKE")
    elif ($m | test("^=== Sidecar Reconnecting"))            then emit("SC"; "RECONNECTING")
    elif ($m | test("^=== Display Hardware Changed"))        then emit("SC"; "HW-CHANGED")
    elif ($m | test("Terminated with Active Sessions"))      then emit("SC"; "RELAY-TERMINATED")
    elif ($m | test("SidecarErrorDomain"))                   then emit("SC"; "ERROR")
    else empty end
  else empty end
