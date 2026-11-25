#!/usr/bin/env python3
"""Tests for nfc_albums.py and buddy.nfc WebSocket handling against mock_display.py."""
from __future__ import annotations

import asyncio
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import clawpal_companion as comp
import clawpal_mac as pairing
import nfc_albums as nfc
from mock_display import MockDisplay


def check(cond: bool, label: str) -> None:
    if not cond:
        raise AssertionError(f"FAIL: {label}")
    print(f"PASS: {label}")


def test_normalization_and_mapping() -> None:
    check(nfc.normalize_uid("04:A1:B2:C3:D4:E5:80") == "04a1b2c3d4e580", "7-byte NTAG UID normalized")
    check(nfc.normalize_uid("DE AD BE EF") == "deadbeef", "4-byte UID normalized")
    check(nfc.normalize_uid("not-hex!") is None, "invalid UID rejected")
    check(nfc.normalize_uid("1234") is None, "short UID rejected")

    check(
        nfc.normalize_spotify_uri("https://open.spotify.com/album/4LH4d3cOWNNsVw41Gqt2kv?si=abc123")
        == "spotify:album:4LH4d3cOWNNsVw41Gqt2kv",
        "Spotify HTTPS album URL normalized",
    )
    check(
        nfc.normalize_spotify_uri("https://open.spotify.com/intl-en/playlist/37i9dQZF1DXcBWIGoYBM5M")
        == "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
        "Spotify localized playlist URL normalized",
    )
    check(
        nfc.normalize_spotify_uri("spotify:album:4LH4d3cOWNNsVw41Gqt2kv")
        == "spotify:album:4LH4d3cOWNNsVw41Gqt2kv",
        "Spotify URI preserved",
    )
    check(nfc.normalize_spotify_uri("https://example.com/album/123") is None, "non-Spotify URL rejected")

    am = nfc.normalize_apple_music_url("https://music.apple.com/gb/playlist/sample-mix/pl.u-00112233445566778899aabbccddeeff")
    check(am is not None and am["service"] == "apple_music" and am["uri"] == "Sample Mix"
          and am["catalog_id"] == "pl.u-00112233445566778899aabbccddeeff"
          and am["url"].startswith("music://music.apple.com/"),
          f"Apple Music playlist URL parsed ({am})")

    with tempfile.TemporaryDirectory() as tmp:
        albums = Path(tmp) / "nfc_albums.json"
        last = Path(tmp) / "last_nfc.json"
        ran = []

        def fake_run(cmd, **_kwargs):
            ran.append(cmd)
            if "-l" in cmd and "JavaScript" in cmd:
                return subprocess.CompletedProcess(cmd, 0, stdout="clicked\n", stderr="")
            if "open location" in cmd[-1]:
                return subprocess.CompletedProcess(cmd, 0, stdout="opened_url\n", stderr="")
            return subprocess.CompletedProcess(cmd, 0, stdout="played\n", stderr="")

        nfc.save_mapping({
            "04a1b2c3d4e580": {"service": "spotify", "uri": "spotify:album:4LH4d3cOWNNsVw41Gqt2kv", "label": "Dark Side"},
            "04112233445566": {"service": "apple_music", "uri": 'In "Rainbows"', "label": "In Rainbows"},
            "04998877665544": am,
        }, albums)

        handler = nfc.NfcAlbums(albums, last, runner=fake_run)
        uid, ok, err = handler.handle_tap("04a1b2c3d4e580")
        check(uid == "04a1b2c3d4e580" and ok and err == "", "mapped Spotify card triggers playback")
        check('play track "spotify:album:4LH4d3cOWNNsVw41Gqt2kv"' in ran[0][2], "Spotify AppleScript exact")

        uid, ok, err = handler.handle_tap("04112233445566")
        check(uid == "04112233445566" and ok and err == "", "mapped Apple Music card triggers playback")
        check('In \\"Rainbows\\"' in ran[1][2], "Apple Music quotes escaped cleanly")

        uid, ok, err = handler.handle_tap("04998877665544")
        check(uid == "04998877665544" and ok and len(ran) == 4 and "JavaScript" in ran[3],
              "un-added Apple Music catalog URL opens page and invokes content-area Play clicker")

        uid, ok, err = handler.handle_tap("04deadbeefcafe")
        check(uid == "04deadbeefcafe" and not ok and err == "unmapped", "unmapped card returns unmapped")
        check(nfc.read_last_tap(last)["uid"] == "04deadbeefcafe", "last_nfc.json records unmapped tap for nfc-add last")


def test_websocket_nfc_roundtrip() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        albums = Path(tmp) / "nfc_albums.json"
        last = Path(tmp) / "last_nfc.json"
        played = []

        def fake_run(cmd, **_kwargs):
            played.append(cmd[2])
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        nfc.save_mapping({
            "04aabbccddeeff": {"service": "spotify", "uri": "spotify:album:4LH4d3cOWNNsVw41Gqt2kv", "label": "DSOTM"},
        }, albums)
        handler = nfc.NfcAlbums(albums, last, runner=fake_run)

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

            mock.pending_controls.append({"type": "buddy.nfc", "v": 1, "uid": "04aabbccddeeff"})

            async def run_brief():
                task = asyncio.create_task(
                    comp.session(mock.device_id, "127.0.0.1", comp.SystemStats(), DummyPlayers(), None, None, handler)
                )
                for _ in range(40):
                    if task.done():
                        task.result()
                    if played:
                        break
                    await asyncio.sleep(0.1)
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

            asyncio.run(run_brief())
            check(len(played) == 1 and "spotify:album:4LH4d3cOWNNsVw41Gqt2kv" in played[0],
                  f"buddy.nfc WebSocket event triggered Spotify playback ({played})")
        finally:
            comp.DISCOVERY_PORT, comp.MONITOR_PORT, comp.HTTP_PORT, comp.TOKEN, pairing.lan = old
            mock.stop()


if __name__ == "__main__":
    test_normalization_and_mapping()
    test_websocket_nfc_roundtrip()
    print("\nAll NFC tests passed.")
