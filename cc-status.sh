#!/bin/sh
# cc-status.sh <state> — report Claude Code status to the host iTerm2 tab.
#
# States: running | idle | attention | reset
#
# Writes iTerm2 OSC 1337 escape codes to the controlling terminal (/dev/tty,
# NOT stdout — Claude Code captures hook stdout for control JSON, so escape
# codes printed there never reach the terminal). Sets two user variables and a
# static tab color:
#   user.ccStatus  — source of truth, watched by the AutoLaunch daemon
#   user.ccIcon    — status glyph, shown via the \(user.ccIcon) title token
#   tab color      — static color (the daemon adds flashing for "attention")
#
# Designed to never break a hook: any failure exits 0 quietly.
set -u

STATE="${1:-idle}"

# The Notification hook fires both for real permission prompts AND for the
# "Claude is waiting for your input" idle notice (~60s after a finished turn).
# Only the former should flash. When invoked by a hook, stdin is the hook's JSON
# payload (a pipe, not a tty); read it and downgrade the idle-waiting case to
# "idle" so finished tabs don't start flashing minutes later. Manual runs
# (stdin is a tty) skip this and behave exactly as the literal argument says.
if [ "$STATE" = "attention" ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  msg=$(jq -r '.message // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$msg" in
    *waiting*) STATE="idle" ;;
  esac
fi

# Find the terminal device to paint. Claude Code may spawn hooks WITHOUT a
# controlling terminal, so /dev/tty can fail with "device not configured". In
# that case walk up the process tree and use the controlling tty of an ancestor
# (the `claude`/shell process attached to the iTerm2 pane). Escape codes written
# to that device are interpreted by iTerm2 just the same.
resolve_tty() {
  # 1. Our own controlling terminal, if usable.
  if { true >/dev/tty; } 2>/dev/null; then
    echo /dev/tty
    return 0
  fi
  # 2. Nearest ancestor with a real tty.
  pid=$PPID
  i=0
  while [ "${pid:-0}" -gt 1 ] && [ "$i" -lt 12 ]; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$t" in
      ttys*|tty*|pts*)
        if [ -w "/dev/$t" ]; then echo "/dev/$t"; return 0; fi ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    i=$((i + 1))
  done
  return 1
}

TTY=$(resolve_tty) || exit 0   # no reachable terminal → nothing to paint

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=""
CONFIG="$SCRIPT_DIR/config.json"

icon=""
color=""

# Preferred: read icon + color from config.json so restyling is one-file.
if command -v jq >/dev/null 2>&1 && [ -r "$CONFIG" ]; then
  icon=$(jq -r --arg s "$STATE" '.states[$s].icon  // ""' "$CONFIG" 2>/dev/null)
  color=$(jq -r --arg s "$STATE" '.states[$s].color // ""' "$CONFIG" 2>/dev/null)
fi

# Fallback: hardcoded defaults so hooks work even without jq/config.
if [ -z "$color" ]; then
  case "$STATE" in
    running)   icon="⚡"; color="E3B341" ;;
    idle)      icon="💤"; color="6E7681" ;;
    attention) icon="🔴"; color="F85149" ;;
  esac
fi

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

esc=$(printf '\033')
bel=$(printf '\007')

# Writes go to the controlling terminal; errors are swallowed so a missing or
# unconfigured /dev/tty (e.g. a detached context) never surfaces as a hook error.
set_var()   { printf '%s]1337;SetUserVar=%s=%s%s' "$esc" "$1" "$(b64 "$2")" "$bel" > "$TTY" 2>/dev/null; }
set_color() { printf '%s]1337;SetColors=tab=%s%s' "$esc" "$1" "$bel" > "$TTY" 2>/dev/null; }

if [ "$STATE" = "reset" ]; then
  set_var ccStatus ""
  set_var ccIcon ""
  set_color "default"
  exit 0
fi

set_var ccStatus "$STATE"
set_var ccIcon "$icon"
[ -n "$color" ] && set_color "$color"
exit 0
