#!/bin/bash
# Installer for the Claude Code -> iTerm2 status plugin.
#   1. Creates a venv and installs the `iterm2` Python package.
#   2. Installs + loads a launchd agent that runs the status daemon (survives
#      reboots and iTerm2 restarts; no iTerm2 "Python runtime" download needed).
#   3. Merges the status hooks into ~/.claude/settings.json (with a backup).
#   4. Prints the one-time iTerm2 setting you must enable.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
WRITER="$SCRIPT_DIR/cc-status.sh"
DAEMON="$SCRIPT_DIR/claude_iterm_status.py"
MENUBAR="$SCRIPT_DIR/menubar.py"
VENV="$SCRIPT_DIR/.venv"
PY="$VENV/bin/python"
LABEL="com.$(whoami).claude-iterm-status"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MENUBAR_LABEL="com.$(whoami).claude-iterm-menubar"
MENUBAR_PLIST="$HOME/Library/LaunchAgents/$MENUBAR_LABEL.plist"
UID_NUM="$(id -u)"

# Load (or reload) a launchd agent for the current GUI session.
load_agent() {
  launchctl bootout  "gui/$UID_NUM/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$2"
}

echo "› Claude Code → iTerm2 status — installer"

# 1. Executable bits + Python venv with the client libraries.
chmod +x "$WRITER" "$DAEMON" "$MENUBAR"
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet iterm2 rumps
echo "✓ venv ready ($("$PY" -c 'import iterm2; print("iterm2", iterm2.__version__)'), rumps)"

# 2a. launchd agent for the tab daemon (colors, flashing, glyph prefix).
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>-u</string>
    <string>$DAEMON</string>
  </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>ProcessType</key>      <string>Background</string>
  <key>StandardOutPath</key>  <string>/tmp/cc-daemon.log</string>
  <key>StandardErrorPath</key><string>/tmp/cc-daemon.log</string>
</dict>
</plist>
PLISTEOF
load_agent "$LABEL" "$PLIST"
echo "✓ tab daemon loaded ($LABEL)"

# 2b. launchd agent for the menu-bar indicator (aggregate glyph, always visible).
cat > "$MENUBAR_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>$MENUBAR_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>-u</string>
    <string>$MENUBAR</string>
  </array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>/tmp/cc-menubar.log</string>
  <key>StandardErrorPath</key><string>/tmp/cc-menubar.log</string>
</dict>
</plist>
PLISTEOF
load_agent "$MENUBAR_LABEL" "$MENUBAR_PLIST"
echo "✓ menu-bar indicator loaded ($MENUBAR_LABEL)"

# 3. Merge hooks into ~/.claude/settings.json.
if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq is required to merge hooks. brew install jq, or merge settings.hooks.json by hand." >&2
  exit 1
fi
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
jq --arg w "$WRITER" '
  .hooks = (.hooks // {})
  | .hooks.SessionStart     = [{hooks:[{type:"command", command:($w+" idle")}]}]
  | .hooks.UserPromptSubmit = [{hooks:[{type:"command", command:($w+" running")}]}]
  | .hooks.PreToolUse       = [{matcher:"*", hooks:[{type:"command", command:($w+" running")}]}]
  | .hooks.PostToolUse      = [{matcher:"*", hooks:[{type:"command", command:($w+" running")}]}]
  | .hooks.Notification     = [{hooks:[{type:"command", command:($w+" attention")}]}]
  | .hooks.Stop             = [{hooks:[{type:"command", command:($w+" idle")}]}]
  | .hooks.SessionEnd       = [{hooks:[{type:"command", command:($w+" reset")}]}]
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "✓ Hooks merged into $SETTINGS (backup alongside)"

cat <<'EOF'

──────────────────────────────────────────────────────────────────
One-time iTerm2 setting (so the daemon may connect to the API):

  iTerm2 → Settings → General → Magic →
     ☑ Enable Python API
     ☑ "Allow all apps to connect"   (avoids a connect prompt on
                                       every daemon (re)start)

That's it — no runtime download, no title field to configure. The
daemon sets the glyph prefix AND the tab color itself. Open a new
Claude Code session and watch the tab.
──────────────────────────────────────────────────────────────────
EOF
