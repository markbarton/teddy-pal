"""
NFC album card mapping and macOS playback for ClawPal.

Cards store no data; only each card's UID (lowercase hex, e.g. 14 chars for NTAG215/216)
is mapped on the Mac in ~/.clawpal-mac/nfc_albums.json.
"""
from __future__ import annotations

import json
import logging
import os
import re
import secrets
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse

log = logging.getLogger("clawpal.nfc")

HOME = Path.home() / ".clawpal-mac"
ALBUMS_FILE = HOME / "nfc_albums.json"
LAST_TAP_FILE = HOME / "last_nfc.json"
UID_RE = re.compile(r"^[0-9a-f]{8,20}$")
SPOTIFY_URI_RE = re.compile(r"^spotify:(album|playlist|track|artist):([A-Za-z0-9]{10,40})$")


def normalize_uid(raw: str) -> str | None:
    cleaned = re.sub(r"[:\-\s]", "", str(raw or "")).lower()
    return cleaned if UID_RE.match(cleaned) else None


def normalize_spotify_uri(target: str) -> str | None:
    text = str(target or "").strip()
    if SPOTIFY_URI_RE.match(text):
        return text
    parsed = urlparse(text)
    if parsed.scheme in ("http", "https") and parsed.netloc in ("open.spotify.com", "play.spotify.com"):
        parts = [p for p in parsed.path.split("/") if p]
        # Handle optional locale prefix like /intl-en/album/<id>
        if len(parts) >= 3 and parts[0].startswith("intl-"):
            parts = parts[1:]
        if len(parts) >= 2 and parts[0] in ("album", "playlist", "track", "artist"):
            uri = f"spotify:{parts[0]}:{parts[1]}"
            if SPOTIFY_URI_RE.match(uri):
                return uri
    return None


def normalize_apple_music_url(target: str) -> dict | None:
    """Parse https://music.apple.com/<cc>/<kind>/<slug>/<id> into structured metadata."""
    text = str(target or "").strip()
    parsed = urlparse(text)
    if parsed.scheme not in ("http", "https", "music") or parsed.netloc not in ("music.apple.com", "itunes.apple.com"):
        return None
    parts = [p for p in parsed.path.split("/") if p]
    # e.g. ['gb', 'playlist', 'your-essentials', 'pl.pm-...'] or ['gb', 'album', 'dark-side', '1065973699']
    if len(parts) >= 4 and parts[1] in ("album", "playlist", "station", "artist"):
        kind, slug, cid = parts[1], parts[2], parts[3]
    elif len(parts) >= 3 and parts[0] in ("album", "playlist", "station", "artist"):
        kind, slug, cid = parts[0], parts[1], parts[2]
    else:
        return None
    title = " ".join(w.capitalize() for w in slug.replace("-", " ").split())
    music_url = f"music://{parsed.netloc}{parsed.path}"
    return {"service": "apple_music", "kind": kind, "uri": title, "url": music_url, "catalog_id": cid, "label": title}


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def _as_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def load_mapping(path: Path = ALBUMS_FILE) -> dict[str, dict]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception as err:
        log.warning("could not read %s: %s", path, err)
        return {}


def save_mapping(mapping: dict[str, dict], path: Path = ALBUMS_FILE) -> None:
    _atomic_write(path, json.dumps(mapping, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def record_last_tap(uid: str, path: Path = LAST_TAP_FILE, now: float | None = None) -> None:
    _atomic_write(path, json.dumps({"uid": uid, "at": time.time() if now is None else now}, indent=2) + "\n")


def read_last_tap(path: Path = LAST_TAP_FILE) -> dict | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and normalize_uid(data.get("uid", "")):
            return data
    except Exception:
        pass
    return None


def play_entry(entry: dict, runner=subprocess.run) -> tuple[bool, str]:
    """Start album/playlist playback in Spotify or Apple Music on macOS."""
    service = str(entry.get("service", "")).lower()
    target = str(entry.get("uri") or entry.get("target") or "").strip()
    if not target:
        return False, "empty target"

    if service == "spotify":
        uri = normalize_spotify_uri(target)
        if not uri:
            return False, "invalid spotify uri"
        script = f'tell application "Spotify"\n  play track "{_as_escape(uri)}"\nend tell'
    elif service in ("apple_music", "music"):
        name = _as_escape(target)
        url = _as_escape(str(entry.get("url") or "").strip())
        if url:
            fallback = (
                f'    open location "{url}"\n'
                '    activate\n'
                '    return "opened_url"\n'
            )
        else:
            fallback = '    error "Playlist or album not found in Music library"\n'
        script = (
            'tell application "Music"\n'
            f'  if exists playlist "{name}" then\n'
            f'    play playlist "{name}"\n'
            '    return "played"\n'
            '  else\n'
            f'    set matches to (every track of library playlist 1 whose album is "{name}")\n'
            '    if (count of matches) > 0 then\n'
            '      if not (exists user playlist "ClawPal NFC") then\n'
            '        make new user playlist with properties {name:"ClawPal NFC"}\n'
            '      else\n'
            '        delete every track of user playlist "ClawPal NFC"\n'
            '      end if\n'
            '      repeat with t in matches\n'
            '        duplicate t to user playlist "ClawPal NFC"\n'
            '      end repeat\n'
            '      play user playlist "ClawPal NFC"\n'
            '      return "played"\n'
            '    else\n'
            f'{fallback}'
            '    end if\n'
            '  end if\n'
            'end tell'
        )
    else:
        return False, f"unsupported service {service!r}"

    try:
        res = runner(["osascript", "-e", script], capture_output=True, text=True, timeout=10)
        if res.returncode != 0:
            return False, (res.stderr or "osascript failed").strip()
        if (res.stdout or "").strip() == "opened_url":
            clicked, hint = _click_music_page_play(runner=runner)
            if not clicked and hint:
                log.info("NFC Apple Music opened page (auto-play note: %s)", hint)
        return True, ""
    except Exception as err:
        return False, str(err)


MUSIC_CLICK_PLAY_JXA = r'''
const se = Application("System Events");
const music = se.processes.byName("Music");
const deadline = Date.now() + 4500;
function findContentPlay(el, depth) {
  if (depth > 18) return null;
  let role = "", name = "", desc = "", title = "";
  try { role = String(el.role() || ""); } catch (e) { return null; }
  if (role === "AXButton") {
    try { name = String(el.name() || ""); } catch (e) {}
    try { title = String(el.title() || ""); } catch (e) {}
    try { desc = String(el.description() || ""); } catch (e) {}
    const label = (name || title || desc).trim();
    if (label === "Play") {
      try {
        const pos = el.position();
        // Skip the top transport-bar Play button (near top edge, y < 120).
        if (pos && pos[1] > 120) return el;
      } catch (e) {}
    }
  }
  let kids = [];
  try { kids = el.uiElements(); } catch (e) { return null; }
  for (let i = 0; i < kids.length; i++) {
    const hit = findContentPlay(kids[i], depth + 1);
    if (hit) return hit;
  }
  return null;
}
let clicked = false;
while (Date.now() < deadline) {
  try {
    const win = music.windows[0];
    const btn = findContentPlay(win, 0);
    if (btn) {
      btn.click();
      clicked = true;
      break;
    }
  } catch (e) {
    if (String(e).indexOf("1719") !== -1) {
      throw e;
    }
  }
  delay(0.35);
}
clicked ? "clicked" : "not_found";
'''


def _click_music_page_play(runner=subprocess.run) -> tuple[bool, str]:
    """Press the content-area Play button on an opened Apple Music catalog page (requires Accessibility)."""
    try:
        res = runner(["osascript", "-l", "JavaScript", "-e", MUSIC_CLICK_PLAY_JXA],
                     capture_output=True, text=True, timeout=8)
        if res.returncode == 0 and (res.stdout or "").strip() == "clicked":
            return True, ""
        err = (res.stderr or "").strip()
        if "1719" in err or "assistive" in err.lower():
            return False, "grant Accessibility to Python in System Settings -> Privacy & Security -> Accessibility (or click + Add to Library in Music)"
        return False, err or (res.stdout or "").strip()
    except Exception as err:
        return False, str(err)


class NfcAlbums:
    """Handles card tap events received from the display over WebSocket."""

    def __init__(self, albums_path: Path = ALBUMS_FILE, last_tap_path: Path = LAST_TAP_FILE,
                 runner=subprocess.run) -> None:
        self.albums_path = albums_path
        self.last_tap_path = last_tap_path
        self.runner = runner

    def handle_tap(self, raw_uid: str) -> tuple[str | None, bool, str]:
        uid = normalize_uid(raw_uid)
        if not uid:
            return None, False, "invalid uid"
        try:
            record_last_tap(uid, self.last_tap_path)
        except Exception as err:
            log.debug("could not save last_nfc.json: %s", err)

        mapping = load_mapping(self.albums_path)
        entry = mapping.get(uid)
        if not isinstance(entry, dict):
            log.info("NFC card %s tapped (unmapped; run: clawpal_companion.py nfc-add last <spotify-url>)", uid)
            return uid, False, "unmapped"

        label = entry.get("label") or entry.get("uri") or uid
        ok, err = play_entry(entry, runner=self.runner)
        if ok:
            log.info("NFC card %s -> playing %s (%s)", uid, label, entry.get("service"))
        else:
            log.warning("NFC card %s -> failed to play %s: %s", uid, label, err)
        return uid, ok, err
