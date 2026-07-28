#!/usr/bin/env python3
"""Claude Code -> iTerm2 live status daemon.

AutoLaunched by iTerm2. Watches the per-session user variable `user.ccStatus`
(set by cc-status.sh from Claude Code hooks) and animates the tab:

    running   -> amber,     steady
    idle      -> dim slate, steady
    attention -> red,       FLASHING   (the only animated state, by design)

The hook's escape codes already set a *static* tab color, so colors work even
without this daemon. The daemon's job is the flashing for `attention` (escape
codes can't animate) and keeping color authoritative while it runs.

Install: symlink/copy this file into
    ~/Library/Application Support/iTerm2/Scripts/AutoLaunch/
and enable the Python API (iTerm2 -> Settings -> General -> Magic).
"""

import asyncio
import json
import os
import time

import iterm2

CONFIG_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "config.json")

# IPC with the menu-bar app (menubar.py): the daemon is the single source of
# truth — it publishes a snapshot of every Claude session here, and consumes
# "focus this session" requests written by the menu bar.
STATE_FILE = "/tmp/cc-iterm-state.json"
FOCUS_FILE = "/tmp/cc-iterm-focus"

# session_id -> {"status": str, "name": str}; published to STATE_FILE on change.
STATUS = {}


def publish_state():
    """Atomically write the current snapshot for the menu-bar app to poll."""
    payload = {
        "sessions": [{"id": sid, **info} for sid, info in STATUS.items()],
        "updated": time.time(),
    }
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass

DEFAULTS = {
    "states": {
        "running":   {"icon": "⚡", "color": "E3B341"},
        "idle":      {"icon": "\U0001f4a4", "color": "6E7681"},
        "attention": {"icon": "\U0001f534", "color": "F85149"},
    },
    "flash": {"interval_ms": 600, "dim_color": "3A0E0C"},
}


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return DEFAULTS


def hex_to_color(h):
    h = h.lstrip("#")
    return iterm2.Color(int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


async def paint(session, color):
    """Apply (color) or clear (None) the tab color for a session."""
    change = iterm2.LocalWriteOnlyProfile()
    if color is None:
        change.set_use_tab_color(False)
    else:
        change.set_tab_color(color)
        change.set_use_tab_color(True)
    await session.async_set_profile_properties(change)


def find_tab(app, session_id):
    """Locate the Tab containing a session (there is no session.tab shortcut)."""
    for window in app.terminal_windows:
        for tab in window.tabs:
            for s in tab.sessions:
                if s.session_id == session_id:
                    return tab
    return None


async def set_prefix(app, session_id, icon):
    """Prefix the tab title with the status glyph (iTerm2 has no UI for this, so
    the daemon owns it). Passing "" clears the override and restores the default.
    The base keeps iTerm2's auto-computed title via the \\(currentSession.autoName)
    interpolation token."""
    tab = find_tab(app, session_id)
    if tab is None:
        return
    await tab.async_set_title(icon + r"  \(currentSession.autoName)" if icon else "")


async def main(connection):
    config = load_config()
    states = config.get("states", DEFAULTS["states"])
    flash_cfg = config.get("flash", DEFAULTS["flash"])
    interval = flash_cfg.get("interval_ms", 600) / 1000.0
    dim = hex_to_color(flash_cfg.get("dim_color", "3A0E0C"))

    app = await iterm2.async_get_app(connection)

    async def focus_watcher():
        """Bring a session to the foreground when the menu bar requests it."""
        while True:
            try:
                if os.path.exists(FOCUS_FILE):
                    with open(FOCUS_FILE) as f:
                        sid = f.read().strip()
                    os.remove(FOCUS_FILE)
                    session = app.get_session_by_id(sid) if sid else None
                    if session is not None:
                        await session.async_activate(True, True)
            except Exception:
                pass
            await asyncio.sleep(0.4)

    asyncio.create_task(focus_watcher())

    async def monitor(session_id):
        session = app.get_session_by_id(session_id)
        if session is None:
            return

        name = await session.async_get_variable("autoName") or session_id
        flash_task = {"t": None}

        async def flash(color_on, color_off):
            on = True
            while True:
                await paint(session, color_on if on else color_off)
                on = not on
                await asyncio.sleep(interval)

        async def apply(status):
            # Any state change cancels an in-flight flash.
            if flash_task["t"] is not None:
                flash_task["t"].cancel()
                flash_task["t"] = None
            if not status:
                STATUS.pop(session_id, None)
                publish_state()
                await set_prefix(app, session_id, "")
                await paint(session, None)
                return
            state = states.get(status)
            if state is None:
                return
            STATUS[session_id] = {"status": status, "name": name}
            publish_state()
            await set_prefix(app, session_id, state.get("icon", ""))
            color = hex_to_color(state["color"])
            if status == "attention":
                flash_task["t"] = asyncio.create_task(flash(color, dim))
            else:
                await paint(session, color)

        try:
            # Paint the current state immediately, then react to every change.
            current = await session.async_get_variable("user.ccStatus")
            await apply(current)
            async with iterm2.VariableMonitor(
                connection, iterm2.VariableScopes.SESSION, "user.ccStatus", session_id
            ) as mon:
                while True:
                    await apply(await mon.async_get())
        finally:
            # Session closed (or monitor torn down): drop it from the snapshot.
            if flash_task["t"] is not None:
                flash_task["t"].cancel()
            STATUS.pop(session_id, None)
            publish_state()

    # Attach to every session, current and future.
    await iterm2.EachSessionOnceMonitor.async_foreach_session_create_task(app, monitor)


iterm2.run_forever(main)
