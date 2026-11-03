# toolline.awk — tools/logs/sidecar.log lines -> timeline lines (tag TOOL).
#   awk -f toolline.awk [-v out=FILE] [-v from=TS -v to=TS]
# With out= every line is appended to FILE and the file is closed again, so the
# timeline can be rotated underneath. from/to (YYYY-MM-DDTHH:MM:SS) filter by time.
BEGIN { OFS = "\t" }
{
  line = $0
  if (line ~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+/) {
    ts = substr(line, 1, 19)
    rest = line; sub(/^[^ ]+ /, "", rest)
  } else {
    # continuation of a multi-line ERROR: keep the timestamp of the line before
    if (ts == "") next
    rest = line
  }
  if (from != "" && ts < from) next
  if (to != "" && ts > to) next
  if (rest ~ /^(status|doctor):/) next          # read-only commands: noise here

  kind = "INFO"
  if (rest ~ /^connect ".*\(attempt/)                      kind = "CONNECT"
  else if (rest ~ /^disconnect ".*(sent|exit)/)            kind = "DISCONNECT"
  else if (rest ~ /^Sidecar connected/)                    kind = "CONNECTED"
  else if (rest ~ /^ERROR/)                                kind = "ERROR"
  else if (rest ~ /^WARN/)                                 kind = "WARN"
  else if (rest ~ /arranged|mirror applied/)               kind = "LAYOUT"

  gsub(/\t/, " ", rest)
  if (out != "") { print ts, "TOOL", kind, rest >> out; close(out) }
  else { print ts, "TOOL", kind, rest; fflush() }
}
