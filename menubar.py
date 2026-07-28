#!/usr/bin/env python3
"""Claude Code status — macOS menu-bar indicator.

A tiny always-visible glyph in the top-right menu bar that aggregates every
Claude Code session, so you can see status even when iTerm2 is hidden.

  • title  = the worst current state across sessions, with counts
             e.g. "🔴1 ⚡2"  (one needs attention, two running);  "💤" when all idle
  • click  = a dropdown of every session by name; clicking one jumps to that tab.

Data comes from the daemon (claude_iterm_status.py), which publishes a snapshot
to STATE_FILE. This app only reads that file and writes focus requests — it never
touches the iTerm2 API itself, so there's no second connection or run-loop clash.
"""

import json
import os
import subprocess

import rumps

STATE_FILE = "/tmp/cc-iterm-state.json"
FOCUS_FILE = "/tmp/cc-iterm-focus"
CONFIG_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "config.json")

PRIORITY = ["attention", "running", "idle"]  # worst -> best
_FALLBACK = {"attention": "🔴", "running": "⚡", "idle": "💤"}


def load_icons():
    """Glyphs come from config.json (shared with the tab daemon) so a restyle is
    one file. Falls back to the defaults if the config is missing/unreadable."""
    try:
        with open(CONFIG_PATH) as f:
            states = json.load(f).get("states", {})
        return {k: states.get(k, {}).get("icon") or _FALLBACK[k] for k in PRIORITY}
    except (OSError, ValueError):
        return dict(_FALLBACK)


ICONS = load_icons()
IDLE_GLYPH = ICONS["idle"]


class ClaudeStatusBar(rumps.App):
    def __init__(self):
        super().__init__(IDLE_GLYPH, quit_button=None)
        self._timer = rumps.Timer(self.refresh, 1)
        self._timer.start()

    def _read_sessions(self):
        try:
            with open(STATE_FILE) as f:
                return json.load(f).get("sessions", [])
        except (OSError, ValueError):
            return []

    def refresh(self, _):
        sessions = self._read_sessions()

        counts = {s: 0 for s in PRIORITY}
        for sess in sessions:
            st = sess.get("status")
            if st in counts:
                counts[st] += 1

        # Title: glyph+count for every active non-idle state, worst first;
        # plain 💤 when nothing is running or waiting.
        parts = [f"{ICONS[s]}{counts[s]}" for s in PRIORITY if s != "idle" and counts[s]]
        self.title = " ".join(parts) if parts else IDLE_GLYPH

        # Rebuild the dropdown.
        self.menu.clear()
        if not sessions:
            self.menu.add(rumps.MenuItem("No Claude sessions"))
        else:
            seen = set()
            # Show worst-status sessions first so the blocked one is at the top.
            order = {s: i for i, s in enumerate(PRIORITY)}
            for sess in sorted(sessions, key=lambda s: order.get(s.get("status"), 99)):
                glyph = ICONS.get(sess.get("status"), "·")
                label = f"{glyph}  {sess.get('name') or sess.get('id', '?')}"
                while label in seen:  # rumps keys on title; keep them unique
                    label += " "
                seen.add(label)
                self.menu.add(rumps.MenuItem(label, callback=self._focus(sess.get("id"))))
        self.menu.add(rumps.separator)
        self.menu.add(rumps.MenuItem("Quit", callback=rumps.quit_application))

    def _focus(self, session_id):
        def callback(_):
            try:
                with open(FOCUS_FILE, "w") as f:
                    f.write(session_id or "")
            except OSError:
                pass
            subprocess.Popen(["open", "-a", "iTerm"])  # bring iTerm2 forward
        return callback


if __name__ == "__main__":
    ClaudeStatusBar().run()
