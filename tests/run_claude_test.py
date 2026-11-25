#!/usr/bin/env python3
"""Tests for claude_code.py: mirrors upstream ClaudeChecks.cs + macOS statusline forwarding + MockDisplay."""
from __future__ import annotations

import asyncio
import io
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import claude_code as cc
import clawpal_companion as comp
import clawpal_mac as pairing
from mock_display import MockDisplay, validate_telemetry_frame


def check(cond: bool, label: str) -> None:
    if not cond:
        raise AssertionError(f"FAIL: {label}")
    print(f"PASS: {label}")


def wrap_frame(claude: dict) -> str:
    return json.dumps({
        "type": "pc.stats", "v": 1, "seq": 1, "timestamp": int(time.time() * 1000),
        "hostname": "Mac-Studio", "uptime_s": 100, "auto_open_apps": False,
        "cpu": {"usage": 10, "temperature": None, "name": "Apple M1 Max"},
        "gpu": {"usage": None, "temperature": None, "vram_used_mb": None, "vram_total_mb": None, "name": ""},
        "memory": {"used_mb": 1000, "total_mb": 4000, "usage": 25},
        "network": {"rx_bps": 0, "tx_bps": 0},
        "claude": claude,
    }, ensure_ascii=False, separators=(",", ":"))


def test_contract() -> None:
    now = 1800000000.0
    row = cc.observe({
        "session_id": "fixture-1",
        "session_name": "Release check",
        "cwd": "/Users/dev/Projects/Example",
        "model": {"display_name": "Sonnet"},
        "rate_limits": {
            "five_hour": {"used_percentage": 27, "resets_at": 1800001800},
            "seven_day": {"used_percentage": 100, "resets_at": 1800300000},
        },
        "prompt": "private prompt",
        "transcript_path": "private transcript",
        "access_token": "private secret",
    }, True, None, now, 123, 456.0)
    assert row is not None
    check(row.primary["remaining_percent"] == 73.0 and row.secondary["available"] and row.secondary["remaining_percent"] == 0.0,
          "percentage means remaining; exhausted quota is available")
    check(row.primary["window_minutes"] == 300 and row.secondary["window_minutes"] == 10080,
          "session and weekly windows are distinct")
    check(row.title == "Release check" and row.project == "Example", "named session and project basename retained")
    encoded = json.dumps(row.to_dict())
    check("private" not in encoded and "Sonnet" not in encoded and "/Users/" not in encoded,
          "secrets, prompts, transcript paths, model, and full paths discarded")

    check(cc.observe({"session_id": "../escape"}, True, None, now) is None, "path traversal session id rejected")
    check(not cc.observe({"session_id": "valid", "rate_limits": {"five_hour": {"used_percentage": -1, "resets_at": 1800001800}}}, True, None, now).primary["available"],
          "negative usage rejected")
    check(not cc.observe({"session_id": "valid", "rate_limits": {"five_hour": {"used_percentage": 101, "resets_at": 1800001800}}}, True, None, now).primary["available"],
          "over-range usage rejected")
    check(not cc.observe({"session_id": "valid", "rate_limits": {"five_hour": {"used_percentage": "42", "resets_at": 1800001800}}}, True, None, now).primary["available"],
          "string usage rejected")
    check(not cc.observe({"session_id": "valid", "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 1700000000}}}, True, None, now).primary["available"],
          "expired window unavailable")
    check(not cc.observe({"session_id": "valid", "context_window": {"used_percentage": 10}}, True, None, now).primary["available"],
          "context window never treated as subscription quota")

    cleared = cc.observe({"session_id": "fixture-1", "rate_limits": None}, True, row, now)
    check(not cleared.primary["available"] and not cleared.secondary["available"], "missing live limits clear older snapshot")

    submit = cc.observe({"session_id": "fixture-1", "hook_event_name": "UserPromptSubmit", "prompt": "secret"}, False, row, now)
    check(submit.state == "working" and submit.primary == row.primary, "UserPromptSubmit keeps usage without retaining prompt")

    wait = cc.observe({"session_id": "fixture-1", "hook_event_name": "PermissionRequest", "tool_input": {"cmd": "private"}}, False, submit, now)
    check(wait.state == "waiting", "PermissionRequest -> waiting")

    notif_wait = cc.observe({"session_id": "fixture-1", "hook_event_name": "Notification", "notification_type": "elicitation_dialog"}, False, submit, now)
    check(notif_wait.state == "waiting", "Notification elicitation_dialog -> waiting")

    notif_idle = cc.observe({"session_id": "fixture-1", "hook_event_name": "Notification", "notification_type": "idle_prompt"}, False, wait, now)
    check(notif_idle.state == "completed", "Notification idle_prompt -> completed")

    stop = cc.observe({"session_id": "fixture-1", "hook_event_name": "Stop"}, False, wait, now)
    check(stop.state == "completed", "Stop -> completed")

    closed = cc.observe({"session_id": "fixture-1", "hook_event_name": "SessionEnd"}, False, stop, now)
    snap = cc.build_snapshot([closed], now, alive_fn=lambda _: True)
    check(not snap["running"] and snap["stale"] and snap["activity"]["working_count"] == 0, "SessionEnd wins over live process")
    ok, err = validate_telemetry_frame(wrap_frame(snap))
    check(ok, f"closed snapshot passes firmware parser ({err})")

    snap = cc.build_snapshot([submit], now + 121, alive_fn=lambda _: True)
    check(snap["stale"] and snap["activity"]["items"][0]["state"] == "unknown", "aged usage cached and work expires after 120s")
    check(validate_telemetry_frame(wrap_frame(snap))[0], "aged snapshot passes firmware parser")

    snap = cc.build_snapshot([wait], now + 1801, alive_fn=lambda _: True)
    check(snap["activity"]["items"][0]["state"] == "unknown", "waiting expires after 1800s")

    snap = cc.build_snapshot([submit], now, alive_fn=lambda _: False)
    check(not snap["running"] and snap["activity"]["working_count"] == 0, "crashed processes cannot remain working")

    other_closed = cc.ClaudeSession(**{**row.to_dict(), "id": "other", "ended": True})
    snap = cc.build_snapshot([other_closed, cleared], now, alive_fn=lambda _: True)
    check(not snap["available"], "live session without quota never borrows closed session quota")

    snap = cc.build_snapshot([row], now + 2 * 86400, alive_fn=lambda _: True)
    check(not snap["running"] and not snap["available"] and not snap["activity"]["available"], "old snapshots disappear")

    many = [cc.ClaudeSession(**{**submit.to_dict(), "id": str(i)}) for i in range(40)]
    snap = cc.build_snapshot(many, now, alive_fn=lambda _: True)
    check(snap["activity"]["total_count"] == 32 and len(snap["activity"]["items"]) == 3, "enumeration and wire rows bounded")
    check(validate_telemetry_frame(wrap_frame(snap))[0], "bounded 3-item snapshot passes firmware parser")

    long_row = cc.observe({"session_id": "unicode", "session_name": "ą" * 80, "cwd": "/tmp/" + "ł" * 60}, True, None, now)
    check(len(long_row.title.encode("utf-8")) <= 63 and len(long_row.project.encode("utf-8")) <= 31, "UTF-8 title & project fit device buffers")
    check(validate_telemetry_frame(wrap_frame(cc.build_snapshot([long_row], now, alive_fn=lambda _: True)))[0],
          "unicode long row passes firmware parser")


def test_bridge_install_uninstall_and_forwarding() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        cdir = root / "claude"
        bdir = root / "bridge"
        cdir.mkdir()
        settings_path = cdir / "settings.json"

        # Realistic settings with third-party hooks + statusLine
        original = json.dumps({
            "permissions": {"allow": ["Read"]},
            "statusLine": {
                "type": "command",
                "command": "cat >/dev/null && printf 'ORCA-STATUS'",
                "padding": 2,
            },
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "say 'I am done'"}]},
                    {"hooks": [{"type": "command", "command": "/bin/sh ~/.orca/claude-hook.sh", "timeout": 10}]},
                ],
                "SubagentStart": [
                    {"matcher": "tldraw-offline", "hooks": [{"type": "command", "command": "node inject.mjs"}]}
                ],
            },
        }, indent=2) + "\n"
        settings_path.write_text(original, encoding="utf-8")

        fake_script = root / "Example's Dir" / "claude_code.py"
        cc.install_bridge(cdir, bdir, sys.executable, fake_script)
        doc = json.loads(settings_path.read_text(encoding="utf-8"))

        check(cc.is_installed(cdir), "is_installed returns True after install")
        check(doc["statusLine"]["padding"] == 2 and doc["statusLine"]["refreshInterval"] == 30, "statusLine visual prefs + refreshInterval preserved")
        check(cc.STATUSLINE_MARKER in doc["statusLine"]["command"], "statusLine points to ClawPal wrapper")
        check(doc["permissions"]["allow"] == ["Read"], "unrelated settings intact")
        check(len(doc["hooks"]["Stop"]) == 3 and doc["hooks"]["Stop"][0]["hooks"][0]["command"] == "say 'I am done'",
              "existing Stop hooks intact alongside ClawPal hook")
        check("SubagentStart" in doc["hooks"], "untouched hook events preserved")
        check((bdir / "settings-before-clawpal.json").read_text(encoding="utf-8") == original, "exact first backup created")

        # Idempotent re-install
        once = settings_path.read_text(encoding="utf-8")
        cc.install_bridge(cdir, bdir, sys.executable, fake_script)
        check(settings_path.read_text(encoding="utf-8") == once, "install_bridge is idempotent")
        check((bdir / "settings-before-clawpal.json").read_text(encoding="utf-8") == original, "re-install keeps original backup")

        # Test real statusline forwarding + state file creation
        payload = json.dumps({
            "session_id": "live-test-1",
            "session_name": "Statusline test",
            "cwd": "/Users/dev/projects/clawpal-mac",
            "model": {"display_name": "Opus"},
            "rate_limits": {
                "five_hour": {"used_percentage": 15.5, "resets_at": int(time.time()) + 3600},
                "seven_day": {"used_percentage": 40.0, "resets_at": int(time.time()) + 86400},
            },
        })
        out = io.StringIO()
        rc = cc.receive(status_line=True, state_directory=bdir, stdin=io.StringIO(payload), stdout=out)
        check(rc == 0 and out.getvalue() == "ORCA-STATUS", f"statusline forwarded stdin/stdout to prior command ({out.getvalue()!r})")

        reader = cc.ClaudeCode(state_directory=bdir, claude_directory=cdir)
        snap = reader.snapshot()
        check(snap["available"] and snap["primary"]["remaining_percent"] == 84.5 and snap["secondary"]["remaining_percent"] == 60.0,
              f"companion read rate_limits from state file ({snap})")
        ok, err = validate_telemetry_frame(wrap_frame(snap))
        check(ok, f"live ClaudeCode snapshot passes firmware parser ({err})")

        # Uninstall restores original statusLine and removes ONLY ClawPal hooks
        cc.uninstall_bridge(cdir, bdir)
        check(not cc.is_installed(cdir), "is_installed returns False after uninstall")
        doc = json.loads(settings_path.read_text(encoding="utf-8"))
        check(doc["statusLine"]["command"] == "cat >/dev/null && printf 'ORCA-STATUS'" and doc["statusLine"]["padding"] == 2,
              "uninstall restores original statusLine verbatim")
        check("refreshInterval" not in doc["statusLine"], "uninstall removes added refreshInterval")
        check(len(doc["hooks"]["Stop"]) == 2 and "PreToolUse" not in doc["hooks"] and "SubagentStart" in doc["hooks"],
              "uninstall removes only ClawPal hooks and empty arrays")
        check(not (bdir / "previous-statusline.json").exists(), "uninstall removes previous-statusline.json")

        # Clean empty settings round trip
        settings_path.write_text("{}", encoding="utf-8")
        cc.install_bridge(cdir, bdir, sys.executable, fake_script)
        cc.uninstall_bridge(cdir, bdir)
        check(json.loads(settings_path.read_text(encoding="utf-8")) == {}, "uninstall leaves no trace on empty settings")

        # Invalid JSON never overwritten
        settings_path.write_text("{broken", encoding="utf-8")
        rejected = False
        try:
            cc.install_bridge(cdir, bdir, sys.executable, fake_script)
        except json.JSONDecodeError:
            rejected = True
        check(rejected and settings_path.read_text(encoding="utf-8") == "{broken", "invalid settings.json never overwritten")


def test_end_to_end_session_with_claude() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        cdir, bdir = root / "claude", root / "bridge"
        cdir.mkdir()
        (cdir / "settings.json").write_text("{}", encoding="utf-8")
        cc.install_bridge(cdir, bdir, sys.executable, ROOT / "claude_code.py")

        cc.store_event({
            "session_id": "e2e-1",
            "session_name": "E2E Claude",
            "cwd": "/Users/dev/projects/clawpal-mac",
            "hook_event_name": "PermissionRequest",
        }, status_line=False, state_directory=bdir)

        claude = cc.ClaudeCode(state_directory=bdir, claude_directory=cdir)
        focused = []
        claude.focus_waiting = lambda: (focused.append("claude"), (True, ""))[1]

        mock = MockDisplay()
        mock.start()
        old = (comp.DISCOVERY_PORT, comp.MONITOR_PORT, comp.HTTP_PORT, comp.TOKEN, pairing.lan)
        try:
            comp.DISCOVERY_PORT = mock.udp_port
            comp.MONITOR_PORT = mock.http_port
            comp.HTTP_PORT = mock.http_port
            comp.TOKEN = mock.token
            pairing.lan = lambda addr: addr == "127.0.0.1" or old[4](addr)

            class DummyPlayers(comp.Players):
                def poll(self) -> None:
                    pass

            mock.pending_controls.append({"type": "buddy.control", "v": 1, "id": 1, "action": "focus", "value": 7})

            async def run_brief():
                task = asyncio.create_task(comp.session(mock.device_id, "127.0.0.1", comp.SystemStats(), DummyPlayers(), None, claude))
                for _ in range(40):
                    if task.done():
                        task.result()
                    if len(mock.frames) >= 2 and focused:
                        break
                    await asyncio.sleep(0.1)
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

            asyncio.run(run_brief())
            check(not mock.rejected, f"mock display accepted all claude frames (rejected={mock.rejected})")
            check(any("claude" in f and f["claude"]["activity"]["items"][0]["state"] == "waiting" for f in mock.frames),
                  "claude waiting session transmitted in pc.stats")
            check(focused == ["claude"], "focus value=7 invoked Claude focus handler")
        finally:
            comp.DISCOVERY_PORT, comp.MONITOR_PORT, comp.HTTP_PORT, comp.TOKEN, pairing.lan = old
            mock.stop()


if __name__ == "__main__":
    test_contract()
    test_bridge_install_uninstall_and_forwarding()
    test_end_to_end_session_with_claude()
    print("\nAll Claude Code tests passed.")
