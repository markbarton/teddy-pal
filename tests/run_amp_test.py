#!/usr/bin/env python3
"""Tests for amp_threads.py (CLI mode and API mapping) validated against mock_display.py."""
from __future__ import annotations

import json
import os
import stat
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import amp_threads
from mock_display import validate_telemetry_frame


def check(cond: bool, label: str) -> None:
    if not cond:
        raise AssertionError(f"FAIL: {label}")
    print(f"PASS: {label}")


def wrap_frame(codex: dict) -> str:
    return json.dumps({
        "type": "pc.stats", "v": 1, "seq": 1, "timestamp": int(time.time() * 1000),
        "hostname": "Mac", "uptime_s": 100, "auto_open_apps": False,
        "cpu": {"usage": 10, "temperature": None, "name": "Apple M1 Max"},
        "gpu": {"usage": None, "temperature": None, "vram_used_mb": None, "vram_total_mb": None, "name": ""},
        "memory": {"used_mb": 1000, "total_mb": 4000, "usage": 25},
        "network": {"rx_bps": 0, "tx_bps": 0},
        "codex": codex,
    })


def test_api_mapping() -> None:
    now = time.time()
    iso = lambda s: datetime.fromtimestamp(now - s, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    threads = [
        {"id": "1", "title": "Approve deploy", "updatedAt": iso(10), "agentState": {"state": "awaiting_approval", "updatedAt": iso(10)},
         "repositories": [{"url": "https://github.com/org/web-app.git"}]},
        {"id": "2", "title": "Second waiting in same repo", "updatedAt": iso(20), "agentState": {"state": "awaiting_approval", "updatedAt": iso(20)},
         "repositories": [{"url": "https://github.com/org/web-app.git"}]},
        {"id": "3", "title": "Build error", "updatedAt": iso(5), "agentState": {"state": "error", "updatedAt": iso(5)},
         "repositories": [{"dir": "/src/api"}]},
        {"id": "4", "title": "Active work", "updatedAt": iso(3), "agentState": {"state": "working", "updatedAt": iso(3)},
         "repositories": [{"dir": "/src/ui"}]},
        {"id": "5", "title": "Subagent", "parentThreadID": "4", "updatedAt": iso(1), "agentState": {"state": "working"}},
    ]
    rows = amp_threads.pick_rows(threads, now)
    check(len(rows) == 3, "pick_rows returns at most 3 rows")
    check(rows[0]["state"] == "waiting" and rows[0]["project"] == "web-app +1", f"waiting first with +1 ({rows[0]})")
    check(rows[1]["state"] == "interrupted" and rows[1]["project"] == "api", f"interrupted second ({rows[1]})")
    check(rows[2]["state"] == "working" and rows[2]["project"] == "ui", f"working third ({rows[2]})")


def test_cli_mode() -> None:
    fake = ROOT / "tests" / "fake_amp"
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    cli = amp_threads.AmpCli(str(fake))
    cli.poll()
    snap = cli.snapshot()
    ok, err = validate_telemetry_frame(wrap_frame(snap))
    check(ok, f"AmpCli snapshot passes firmware parser ({err})")
    items = snap["activity"]["items"]
    check(len(items) == 2, f"old thread excluded, 2 recent items ({len(items)})")
    check(items[0]["state"] == "working" and items[0]["project"] == "clawpal-mac", f"recent working row ({items[0]})")
    check(items[1]["state"] == "recent" and items[1]["project"] == "", f"workspace runner stripped ({items[1]})")


if __name__ == "__main__":
    test_api_mapping()
    test_cli_mode()
    print("\nAll Amp tests passed.")
