#!/usr/bin/env python3
"""Protocol & companion frame tests against mock_display.py."""
from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import clawpal_companion as comp
import clawpal_mac as pairing
from mock_display import MockDisplay, validate_telemetry_frame


def check(cond: bool, label: str) -> None:
    if not cond:
        raise AssertionError(f"FAIL: {label}")
    print(f"PASS: {label}")


def test_parser_rules() -> None:
    base = {
        "type": "pc.stats", "v": 1, "seq": 1, "timestamp": 1760000000000,
        "hostname": "Mac-Studio", "uptime_s": 3600, "auto_open_apps": False,
        "cpu": {"usage": 22.5, "temperature": None, "name": "Apple M1 Max"},
        "gpu": {"usage": None, "temperature": None, "vram_used_mb": None, "vram_total_mb": None, "name": "Apple M1 Max GPU"},
        "memory": {"used_mb": 16000, "total_mb": 32768, "usage": 48.8},
        "network": {"rx_bps": 1000, "tx_bps": 500},
        "music": {
            "running": True, "available": True, "playing": True, "title": "Track", "artist": "Artist",
            "album": "Album", "position_s": 10, "duration_s": 200, "can_play_pause": True,
            "can_next": True, "can_previous": True, "can_shuffle": True, "shuffle": False,
            "can_repeat": True, "repeat": 2, "can_seek": True, "can_volume": True,
            "volume": 50, "muted": False, "source": "Spotify", "art_color": 0x123456, "art_id": 77,
        },
        "claude": {
            "running": True, "available": True, "stale": False, "status": "ready", "plan": "", "age_s": 5,
            "primary": {"available": True, "remaining_percent": 73.0, "window_minutes": 300, "reset_text": "", "resets_at": 1800001800},
            "secondary": {"available": True, "remaining_percent": 0.0, "window_minutes": 10080, "reset_text": "", "resets_at": 1800300000},
            "activity": {
                "available": True, "stale": False, "status": "local", "age_s": 0,
                "working_count": 1, "total_count": 2,
                "items": [
                    {"title": "Fix bug", "project": "clawpal-mac", "state": "working", "age_s": 3},
                    {"title": "Approve tool", "project": "clawpal-mac", "state": "waiting", "age_s": 9},
                ],
            },
        },
    }
    ok, err = validate_telemetry_frame(json.dumps(base))
    check(ok, f"valid full frame with claude accepted ({err})")

    # String byte limits: < buffer size
    bad = json.loads(json.dumps(base))
    bad["claude"]["activity"]["items"][0]["title"] = "a" * 64
    check(not validate_telemetry_frame(json.dumps(bad))[0], "64-byte claude task title rejected")
    bad["claude"]["activity"]["items"][0]["title"] = "a" * 63
    check(validate_telemetry_frame(json.dumps(bad))[0], "63-byte claude task title accepted")

    bad = json.loads(json.dumps(base))
    bad["claude"]["activity"]["items"][0]["project"] = "p" * 32
    check(not validate_telemetry_frame(json.dumps(bad))[0], "32-byte claude project rejected")

    bad = json.loads(json.dumps(base))
    bad["claude"]["activity"]["items"].append({"title": "3", "project": "p", "state": "recent", "age_s": 1})
    check(validate_telemetry_frame(json.dumps(bad))[0], "3 claude activity items accepted")
    bad["claude"]["activity"]["items"].append({"title": "4", "project": "p", "state": "recent", "age_s": 1})
    check(not validate_telemetry_frame(json.dumps(bad))[0], "4 claude activity items rejected")

    bad = json.loads(json.dumps(base))
    bad["claude"]["activity"]["items"][0]["state"] = "hacking"
    check(not validate_telemetry_frame(json.dumps(bad))[0], "unknown claude item state rejected")

    bad = json.loads(json.dumps(base))
    bad["claude"]["primary"]["remaining_percent"] = None
    check(not validate_telemetry_frame(json.dumps(bad))[0], "null remaining_percent rejected")

    bad = json.loads(json.dumps(base))
    bad["claude"]["running"] = 1
    check(not validate_telemetry_frame(json.dumps(bad))[0], "non-bool claude.running rejected")

    # Frame size limits: 4096 without claude, 6144 with claude
    no_claude = json.loads(json.dumps(base))
    del no_claude["claude"]
    no_claude["pad"] = "x" * 4100
    check(not validate_telemetry_frame(json.dumps(no_claude))[0], ">4096 without claude rejected")
    with_claude = json.loads(json.dumps(base))
    with_claude["pad"] = "x" * 4200
    check(validate_telemetry_frame(json.dumps(with_claude))[0], "4200-6144 bytes with claude accepted")
    with_claude["pad"] = "x" * 6200
    check(not validate_telemetry_frame(json.dumps(with_claude))[0], ">6144 with claude rejected")

    # display_text UTF-8 boundary truncation
    txt = comp.display_text("ą" * 40, 64)
    check(len(txt.encode()) < 64 and txt == "ą" * 31, "display_text truncates cleanly on UTF-8 boundary")
    check(comp.display_text("a\x01b\u2028c", 32) == "abc", "display_text strips control chars and U+2028")


def test_cover_and_session() -> None:
    from PIL import Image
    import io

    buf = io.BytesIO()
    Image.new("RGB", (300, 300), (220, 40, 60)).save(buf, format="PNG")
    cover = comp.make_cover(buf.getvalue())
    check(cover is not None and len(cover.pixels) == 160 * 160 * 2 and cover.color > 0, "make_cover produces RGB565 + vivid accent")

    # Full WS session + play_pause round trip against MockDisplay
    mock = MockDisplay()
    mock.start()
    old_ports = (comp.DISCOVERY_PORT, comp.MONITOR_PORT, comp.HTTP_PORT, comp.TOKEN, pairing.lan)
    try:
        comp.DISCOVERY_PORT = mock.udp_port
        comp.MONITOR_PORT = mock.http_port
        comp.HTTP_PORT = mock.http_port
        comp.TOKEN = mock.token
        pairing.lan = lambda addr: addr == "127.0.0.1" or old_ports[4](addr)

        executed = []

        class FakePlayers(comp.Players):
            def poll(self) -> None:
                pass

            def execute(self, action: str, value: int | None) -> tuple[bool, str]:
                executed.append((action, value))
                return True, ""

        players = FakePlayers()
        players.track = comp.Track("Spotify", "playing", "Song", "Artist", "Album", 200, 10)
        players.running = {"Spotify"}
        players.cover = cover
        stats = comp.SystemStats()
        mock.pending_controls.append({"type": "buddy.control", "v": 1, "id": 1, "action": "play_pause"})

        # Simulate a slow, failing /art upload: telemetry must keep ticking at 1 Hz without dropping the WS.
        upload_calls = []
        orig_signed_post = comp.signed_post

        def slow_failing_post(*_args, **_kwargs):
            upload_calls.append(time.monotonic())
            time.sleep(1.5)
            raise TimeoutError("simulated /art timeout")

        comp.signed_post = slow_failing_post
        try:
            async def run_brief():
                task = asyncio.create_task(comp.session(mock.device_id, "127.0.0.1", stats, players))
                for _ in range(40):
                    if task.done():
                        task.result()
                    if len(mock.frames) >= 3 and any(f["music"].get("control_id") == 1 for f in mock.frames):
                        break
                    await asyncio.sleep(0.1)
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

            t0 = time.monotonic()
            asyncio.run(run_brief())
            elapsed = time.monotonic() - t0
        finally:
            comp.signed_post = orig_signed_post
        check(not mock.rejected, f"mock display rejected 0 frames (rejected={mock.rejected})")
        check(len(mock.frames) >= 3, f"mock display received {len(mock.frames)} valid frames")
        check(len(upload_calls) == 1 and elapsed < 3.5, f"background /art upload failed cleanly without blocking telemetry ({elapsed:.2f}s)")
        check(executed == [("play_pause", None)], f"play_pause executed ({executed})")
        check(any(f["music"].get("control_id") == 1 and f["music"].get("control_ok") is True for f in mock.frames),
              "control ack reported back in telemetry")
    finally:
        comp.DISCOVERY_PORT, comp.MONITOR_PORT, comp.HTTP_PORT, comp.TOKEN, pairing.lan = old_ports
        mock.stop()


if __name__ == "__main__":
    test_parser_rules()
    test_cover_and_session()
    print("\nAll protocol tests passed.")
