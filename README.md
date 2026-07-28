# Claude Code → iTerm2 Live Status

See what every Claude Code session is doing, at a glance, across all your iTerm2 tabs —
**and** in your Mac menu bar even when iTerm2 is hidden. Each tab gets a live status glyph
+ tab color (the one that needs you **flashes**), and a top-right menu-bar glyph aggregates
everything.

| State | When | Glyph | Tab color | Flashing |
|-------|------|:-----:|-----------|:--------:|
| **running** | Claude is thinking / a tool is executing | ⚡ | amber | — |
| **idle** | turn finished, nothing needed | 💤 | dim slate | — |
| **needs attention** | Claude is blocked on a **permission prompt** | 🔴 | red | **yes** |

**Design principle: only "needs attention" flashes.** Idle is the quietest state on
purpose, so a wall of finished tabs recedes and the genuinely-blocked one is unmissable.

## How it works

```
Claude Code hooks ──► cc-status.sh <state> ──(escape codes → terminal device)──┐
                                                                               ▼
                                        iTerm2 session var  user.ccStatus  +  static tab color
                                                              │
                                                              ▼
              claude_iterm_status.py (daemon) watches user.ccStatus and, per tab:
                • sets the glyph prefix on the title  (⚡ / 💤 / 🔴)
                • flashes the color for "attention"   (escape codes can't animate)
                • publishes a snapshot of all sessions ─────► /tmp/cc-iterm-state.json
                                                                       │  (poll 1s)
                                                                       ▼
                                              menubar.py — top-right glyph + session list;
                                              click a session ──► /tmp/cc-iterm-focus ──► daemon
                                                                  activates that tab
```

- **`cc-status.sh`** — invoked by Claude Code hooks on each lifecycle event. Writes iTerm2
  `OSC 1337` escape codes to the controlling terminal device. Because Claude Code may spawn
  hooks **without** a controlling terminal (so `/dev/tty` can fail with "device not
  configured"), the script walks up the process tree to the `claude` process's tty and
  writes there. Sets `user.ccStatus`, `user.ccIcon`, and a static tab color — so colors
  work even with **no daemon**. It also disambiguates the `Notification` hook: Claude fires
  it both for permission prompts *and* for the "waiting for your input" idle notice (~60s
  after a finished turn), so the script reads the hook's JSON payload on stdin and only
  flashes (`attention`) for real prompts — the idle case maps to `idle`, so finished tabs
  don't start flashing minutes later.
- **`claude_iterm_status.py`** — the daemon (run via launchd, see Install). Watches
  `user.ccStatus` per session, sets the **glyph prefix** on the tab title
  (`tab.async_set_title` — iTerm2 has no UI field for this), **flashes** the tab for
  `attention`, **publishes** a snapshot of all sessions to `/tmp/cc-iterm-state.json`, and
  fulfils focus requests from the menu bar. Requires the Python API enabled.
- **`menubar.py`** — a [`rumps`](https://github.com/jaredks/rumps) menu-bar app. Polls the
  snapshot file (it never touches the iTerm2 API itself — no second connection, no run-loop
  clash) and shows the worst current state with counts, e.g. `🔴1 ⚡2`. Clicking a session
  in its dropdown writes a focus request the daemon acts on, jumping you to that tab.

## Install

```sh
./install.sh
```

The installer (needs `jq` — `brew install jq`):
1. creates a `.venv` and installs the `iterm2` + `rumps` libraries,
2. installs + loads two **launchd agents** (`RunAtLoad` + `KeepAlive`, so they start at
   login and self-restart): `com.<username>.claude-iterm-status` (tab daemon) and
   `com.<username>.claude-iterm-menubar` (menu-bar indicator),
3. merges the hooks into `~/.claude/settings.json` (backing it up first).

> **Why launchd instead of iTerm2's AutoLaunch?** AutoLaunch needs iTerm2's bundled Python
> runtime (a separate ~hundreds-of-MB download that doesn't always trigger). Running the
> daemon from a venv via launchd is self-contained and connects over the same Python API —
> no runtime download, and it survives iTerm2 restarts.

Then do the **one-time iTerm2 setting** (the installer reprints it):

- iTerm2 → Settings → General → Magic →
  - ☑ **Enable Python API**
  - ☑ **Allow all apps to connect** — otherwise iTerm2 prompts on every daemon (re)start.

The daemon sets both the glyph prefix and the tab color itself — iTerm2 has no usable UI
field for a custom interpolated title, so there is nothing to configure there. Open a new
Claude Code session and watch the tab.

## Verify

1. `jq . ~/.claude/settings.json` parses and shows a `hooks` block.
2. Both agents are up:
   ```sh
   launchctl print "gui/$(id -u)/com.$(whoami).claude-iterm-status"  | grep state
   launchctl print "gui/$(id -u)/com.$(whoami).claude-iterm-menubar" | grep state
   ```
3. A glyph appears in the top-right menu bar (`💤` when all idle).
4. Run `claude`, submit a prompt that runs a tool → tab goes **⚡ amber**; finishes → **💤 dim**.
5. Trigger a permission prompt → tab goes **🔴 red and flashing**; approve → flashing stops.
6. Manual smoke test, independent of Claude (run in an iTerm2 tab):
   ```sh
   ./cc-status.sh attention   # tab flashes red; menu bar shows 🔴1
   ./cc-status.sh reset       # back to default
   ```
7. Click the menu-bar glyph → the dropdown lists sessions; clicking one jumps to that tab.

## Customize

Edit **`config.json`** — colors (hex, no `#`), glyphs, flash interval, and the dim color
used between flashes. The shell writer, the daemon, and the menu-bar app all read it, so one
edit restyles everything. Reload after editing:
```sh
launchctl kickstart -k "gui/$(id -u)/com.$(whoami).claude-iterm-status"
launchctl kickstart -k "gui/$(id -u)/com.$(whoami).claude-iterm-menubar"
```

## Caveats

- **Split panes**: tab color is per-*tab*. Two Claude sessions in the same tab will fight
  over the color; the glyph/color reflect whichever wrote last. One session per tab is best.
- **No daemon**: the tab **color** still works (the hook sets it via escape codes); you only
  lose the **flashing** and the **glyph prefix**, which the daemon owns.
- **Stale color after a crash**: normal exit fires the `SessionEnd` hook (resets the tab).
  A hard kill can leave the last color until you reuse the tab.

## Uninstall

```sh
launchctl bootout "gui/$(id -u)/com.$(whoami).claude-iterm-status"  2>/dev/null
launchctl bootout "gui/$(id -u)/com.$(whoami).claude-iterm-menubar" 2>/dev/null
rm ~/Library/LaunchAgents/com.$(whoami).claude-iterm-status.plist
rm ~/Library/LaunchAgents/com.$(whoami).claude-iterm-menubar.plist
```
Then restore the most recent `~/.claude/settings.json.bak.*` (or delete the `hooks` block).
