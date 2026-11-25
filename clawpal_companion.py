#!/usr/bin/env python3
"""
clawpal_companion.py - the Mac side of ClawPal. Feeds a paired display over your Wi-Fi.

  run             Find the display, connect, and send stats once a second until stopped.
  install-agent   Start the companion automatically at login (a launchd user agent).
  remove-agent    Stop doing that.
  amp-setup       Show Amp threads (waiting, working, done) on the display's Codex page.
  claude-setup    Install reversible Claude Code hooks + status-line wrapper (display app 7).
  claude-remove   Remove ClawPal's Claude Code hooks and restore your prior status line.
  nfc-list        Show mapped NFC album cards and the last tapped card UID.
  nfc-add         Map an NFC card UID (or 'last') to a Spotify URL/URI or Apple Music album/playlist.
  nfc-remove      Remove a mapped NFC card UID.

What it sends: CPU, memory, network, uptime, and what Spotify or Apple Music is playing
(with album art). The display's play/pause, next, previous, shuffle, repeat, seek and volume
controls work on whichever of the two is playing.

Pair first with  clawpal_mac.py install ; this reads the same Keychain token and config.
Needs:  pip install 'websockets>=15' psutil Pillow
Protocol: docs/PROTOCOL.md in github.com/Kaayoos/clawpal (GPLv3, MinimalPulse).
"""
from __future__ import annotations

import argparse, asyncio, colorsys, hashlib, hmac, io, json, logging, os, plistlib, secrets, socket
import subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from dataclasses import dataclass, field
from pathlib import Path

import amp_threads
import claude_code
import clawpal_mac as pairing
import nfc_albums

DISCOVERY_PORT, MONITOR_PORT = 42170, 42171
HTTP_PORT = MONITOR_PORT     # the display serves HTTP and the WebSocket on one port
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
FRAME_LIMIT = 4096          # 4096 bytes without `claude`, 6144 bytes with `claude`
CLAUDE_FRAME_LIMIT = 6144
COVER_SIZE = 160
AGENT_LABEL = os.environ.get("CLAWPAL_AGENT_LABEL", "dev.teddypal.companion")
log = logging.getLogger("clawpal")


# ----------------------------------------------------------------------------- text limits

def display_text(value: object, max_bytes: int) -> str:
    """Make a string the firmware will accept: printable UTF-8 under its buffer size."""
    text = "".join(ch for ch in str(value or "") if ord(ch) >= 32 and not 0x7F <= ord(ch) <= 0x9F
                   and ch not in "  " and not 0xD800 <= ord(ch) <= 0xDFFF)
    raw = text.encode()
    if len(raw) < max_bytes:
        return text
    return raw[:max_bytes - 1].decode(errors="ignore")


# ----------------------------------------------------------------------------- auth

@dataclass
class Endpoint:
    host: str
    device: str
    challenge: str
    counter: int = 0

    def sign(self, method: str, path: str, body_hash: str = EMPTY_SHA256) -> str:
        self.counter += 1
        message = f"clawpal-auth-v2\n{method}\n{path}\n{self.challenge}\n{self.counter}\n{body_hash}"
        signature = hmac.new(TOKEN.encode(), message.encode(), hashlib.sha256).hexdigest()
        return f"ClawPal-HMAC c={self.challenge},n={self.counter},s={signature}"


TOKEN = ""


def discover(device: str, host: str | None, tries: int = 3) -> Endpoint | None:
    """One UDP round: broadcast (and unicast to the last known address), accept only a valid proof."""
    nonce = secrets.token_hex(16)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(1.0)
    targets = ["255.255.255.255"] + ([host] if host else [])
    try:
        for _ in range(tries):
            for target in targets:
                try:
                    sock.sendto(f"BUDDYOS_DISCOVER_V1 {nonce}".encode(), (target, DISCOVERY_PORT))
                except OSError as error:
                    log.debug("discovery to %s failed: %s", target, error)
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                try:
                    payload, (sender, _) = sock.recvfrom(1024)
                except socket.timeout:
                    break
                try:
                    hello = json.loads(payload)
                except ValueError:
                    continue
                if (not pairing.lan(sender) or hello.get("type") != "buddy.hello" or hello.get("v") != 2
                        or hello.get("nonce") != nonce or hello.get("id") != device):
                    continue
                challenge = str(hello.get("challenge", ""))
                proof = hmac.new(TOKEN.encode(), f"{nonce}|{device}|{MONITOR_PORT}|{challenge}".encode(),
                                 hashlib.sha256).hexdigest()
                if hmac.compare_digest(proof, str(hello.get("proof", ""))):
                    return Endpoint(sender, device, challenge)
    finally:
        sock.close()
    return None


def signed_post(endpoint: Endpoint, path: str, body: bytes, headers: dict[str, str]) -> int:
    body_hash = hashlib.sha256(body).hexdigest()
    request = urllib.request.Request(f"http://{endpoint.host}:{HTTP_PORT}{path}", data=body, method="POST")
    request.add_header("Authorization", endpoint.sign("POST", path, body_hash))
    request.add_header("X-ClawPal-Body-SHA256", body_hash)
    request.add_header("Content-Type", "application/octet-stream")
    for key, value in headers.items():
        request.add_header(key, value)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


# ----------------------------------------------------------------------------- system stats

class SystemStats:
    def __init__(self) -> None:
        import psutil
        self.psutil = psutil
        psutil.cpu_percent(None)
        self.net = psutil.net_io_counters()
        self.net_at = time.monotonic()
        self.hostname = display_text(socket.gethostname().split(".")[0], 64)
        self.cpu_name = display_text(self._sysctl("machdep.cpu.brand_string") or "Mac", 96)

    @staticmethod
    def _sysctl(name: str) -> str:
        try:
            return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=2).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    def sample(self) -> dict:
        ps = self.psutil
        memory = ps.virtual_memory()
        used = memory.total - memory.available
        now, net = time.monotonic(), ps.net_io_counters()
        elapsed = max(now - self.net_at, 0.001)
        rx = max(net.bytes_recv - self.net.bytes_recv, 0) * 8 / elapsed
        tx = max(net.bytes_sent - self.net.bytes_sent, 0) * 8 / elapsed
        self.net, self.net_at = net, now
        disk = ps.disk_usage("/")
        disk_used_mb = round(disk.used / 1048576)
        disk_total_mb = round(disk.total / 1048576)
        disk_pct = round(min(max(disk.used / max(disk.total, 1) * 100, 0), 100), 1)
        return {
            "hostname": self.hostname,
            "uptime_s": int(max(time.time() - ps.boot_time(), 0)),
            # macOS gives no CPU temperature without root; GPU slot carries root Disk Space.
            "cpu": {"usage": round(min(max(ps.cpu_percent(None), 0), 100), 1), "temperature": None,
                    "name": self.cpu_name},
            "gpu": {"usage": disk_pct, "temperature": None, "vram_used_mb": disk_used_mb,
                    "vram_total_mb": disk_total_mb, "name": "Macintosh HD"},
            "memory": {"used_mb": round(used / 1048576), "total_mb": round(memory.total / 1048576),
                       "usage": round(min(used / memory.total * 100, 100), 1)},
            "network": {"rx_bps": round(rx), "tx_bps": round(tx)},
        }


# ----------------------------------------------------------------------------- music

SEP = "\x1f"


def osascript(script: str, timeout: float = 4) -> str:
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "osascript failed")
    return result.stdout.rstrip("\n")


def running_apps() -> set[str]:
    import psutil
    names = set()
    for process in psutil.process_iter(["name"]):
        if process.info["name"] in ("Spotify", "Music"):
            names.add(process.info["name"])
    return names


# Each script only runs while its app is already open, so polling never launches a player.
SPOTIFY_STATE = f'''tell application "Spotify"
  set s to (player state as text)
  if s is "stopped" then return s
  set t to current track
  return s & "{SEP}" & (name of t) & "{SEP}" & (artist of t) & "{SEP}" & (album of t) & "{SEP}" & ((duration of t) div 1000) & "{SEP}" & (player position as integer) & "{SEP}" & shuffling & "{SEP}" & repeating & "{SEP}" & sound volume & "{SEP}" & (id of t) & "{SEP}" & (artwork url of t)
end tell'''

MUSIC_STATE = f'''tell application "Music"
  set s to (player state as text)
  if s is "stopped" then return s
  set t to current track
  return s & "{SEP}" & (name of t) & "{SEP}" & (artist of t) & "{SEP}" & (album of t) & "{SEP}" & ((duration of t) as integer) & "{SEP}" & (player position as integer) & "{SEP}" & shuffle enabled & "{SEP}" & (song repeat as text) & "{SEP}" & sound volume & "{SEP}" & (persistent ID of t) & "{SEP}"
end tell'''

MUSIC_ART = '''tell application "Music"
  set d to raw data of artwork 1 of current track
end tell
set f to open for access (POSIX file "{path}") with write permission
set eof f to 0
write d to f
close access f'''


@dataclass
class Track:
    app: str
    state: str
    title: str = ""
    artist: str = ""
    album: str = ""
    duration: int = 0
    position: int = 0
    shuffle: bool = False
    repeat: int = 0
    volume: int = 0
    track_id: str = ""
    art_url: str = ""


def read_player(app: str) -> Track | None:
    try:
        raw = osascript(SPOTIFY_STATE if app == "Spotify" else MUSIC_STATE)
    except (RuntimeError, subprocess.SubprocessError) as error:
        log.debug("%s state unavailable: %s", app, error)
        return None
    parts = raw.split(SEP)
    if parts[0] == "stopped" or len(parts) < 11:
        return Track(app, "stopped")
    repeat = {"true": 2, "false": 0, "off": 0, "one": 1, "all": 2}.get(parts[7], 0)

    def number(text: str) -> int:
        try:
            return max(int(float(text.replace(",", "."))), 0)
        except ValueError:
            return 0
    return Track(app, parts[0], parts[1], parts[2], parts[3], number(parts[4]), number(parts[5]),
                 parts[6] == "true", repeat, min(number(parts[8]), 100), parts[9], parts[10])


@dataclass
class Cover:
    id: int
    pixels: bytes
    color: int


def make_cover(image_bytes: bytes) -> Cover | None:
    from PIL import Image, ImageOps
    try:
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as error:   # Pillow raises several types for bad images
        log.debug("cover unreadable: %s", error)
        return None
    image = ImageOps.fit(image, (COVER_SIZE, COVER_SIZE), Image.LANCZOS)
    rgb = image.tobytes()
    out = bytearray(COVER_SIZE * COVER_SIZE * 2)
    for i in range(0, len(rgb), 3):
        value = (rgb[i] >> 3) << 11 | (rgb[i + 1] >> 2) << 5 | rgb[i + 2] >> 3
        o = i // 3 * 2
        out[o], out[o + 1] = value & 0xFF, value >> 8
    pixels = bytes(out)
    cover_id = int.from_bytes(hashlib.sha256(pixels).digest()[:4], "little") & 0x7FFFFFFF
    return Cover(cover_id or 1, pixels, accent_color(rgb))


def accent_color(rgb: bytes) -> int:
    """Port of ClawPal's MusicContract.AccentColor: the cover's dominant vivid hue, or 0."""
    bins = [[0.0, 0.0, 0.0, 0.0] for _ in range(12)]
    total, pixels = 0.0, len(rgb) // 3
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i] / 255, rgb[i + 1] / 255, rgb[i + 2] / 255
        high, low = max(r, g, b), min(r, g, b)
        chroma = high - low
        weight = chroma * chroma * (1 - abs(high + low - 1))
        if weight <= 0:
            continue
        hue = colorsys.rgb_to_hsv(r, g, b)[0]
        slot = bins[int(hue * 12) % 12]
        slot[0] += weight; slot[1] += r * weight; slot[2] += g * weight; slot[3] += b * weight
        total += weight
    if total < pixels * 0.004:
        return 0
    best = max(bins, key=lambda slot: slot[0])
    r, g, b = best[1] / best[0], best[2] / best[0], best[3] / best[0]
    hue, lightness, saturation = colorsys.rgb_to_hls(r, g, b)
    r, g, b = colorsys.hls_to_rgb(hue, min(max(lightness, 0.58), 0.7), min(max(saturation, 0.5), 0.85))
    return round(r * 255) << 16 | round(g * 255) << 8 | round(b * 255)


class Players:
    """Spotify and Apple Music through AppleScript. The playing one wins; Spotify breaks ties."""

    def __init__(self) -> None:
        self.track: Track | None = None
        self.running: set[str] = set()
        self.cover: Cover | None = None
        self._cover_key = ""
        self._muted_volume: dict[str, int] = {}
        self._lock = threading.Lock()

    def poll(self) -> None:
        running = running_apps()
        tracks = [t for t in (read_player(app) for app in ("Spotify", "Music") if app in running) if t]
        playing = [t for t in tracks if t.state == "playing"]
        paused = [t for t in tracks if t.state == "paused"]
        track = (playing or paused or [None])[0]
        with self._lock:
            self.running, self.track = running, track
        key = f"{track.app}:{track.track_id}:{track.album}" if track and track.state != "stopped" else ""
        if key and key != self._cover_key:
            self._cover_key = key
            cover = self._fetch_cover(track)
            with self._lock:
                self.cover = cover
        elif not key:
            self._cover_key = ""
            with self._lock:
                self.cover = None

    def _fetch_cover(self, track: Track) -> Cover | None:
        try:
            if track.app == "Spotify" and track.art_url.startswith("https://"):
                with urllib.request.urlopen(track.art_url, timeout=8) as response:
                    return make_cover(response.read(4_000_000))
            if track.app == "Music":
                with tempfile.TemporaryDirectory() as folder:
                    path = Path(folder) / "cover"
                    osascript(MUSIC_ART.replace("{path}", str(path)), timeout=6)
                    return make_cover(path.read_bytes())
        except Exception as error:      # a missing cover just shows the crab
            log.debug("no cover for %s: %s", track.title, error)
        return None

    def snapshot(self, control: tuple[int, bool, str]) -> dict:
        with self._lock:
            track, running, cover = self.track, self.running, self.cover
        live = track is not None and track.state != "stopped"
        music = {"running": bool(running), "available": live, "playing": live and track.state == "playing",
                 "title": display_text(track.title if live else "", 192),
                 "artist": display_text(track.artist if live else "", 128),
                 "album": display_text(track.album if live else "", 128),
                 "position_s": min(track.position, 604800) if live else 0,
                 "duration_s": min(track.duration, 604800) if live else 0,
                 "can_play_pause": live, "can_next": live, "can_previous": live,
                 "can_shuffle": live, "shuffle": live and track.shuffle,
                 "can_repeat": live, "repeat": track.repeat if live else 0,
                 "can_seek": live and track.duration > 0, "can_volume": live,
                 "volume": track.volume if live else 0,
                 "muted": live and track.app in self._muted_volume,
                 "source": "Spotify" if live and track.app == "Spotify" else "Apple Music" if live else "",
                 "art_color": cover.color if live and cover else 0,
                 "art_id": cover.id if live and cover else 0}
        if control[0]:
            music.update(control_id=control[0], control_ok=control[1], control_error=control[2])
        return music

    def execute(self, action: str, value: int | None) -> tuple[bool, str]:
        with self._lock:
            track = self.track
        if not track or track.state == "stopped":
            return False, "unavailable"
        app = track.app
        toggle_repeat = ("set repeating to not repeating" if app == "Spotify" else
                         'if song repeat is off then\nset song repeat to all\nelse if song repeat is all then\n'
                         'set song repeat to one\nelse\nset song repeat to off\nend if')
        commands = {
            "play_pause": "playpause", "next": "next track", "previous": "previous track",
            "shuffle": "set shuffling to not shuffling" if app == "Spotify" else "set shuffle enabled to not shuffle enabled",
            "repeat": toggle_repeat,
        }
        if action == "seek" and value is not None:
            commands["seek"] = f"set player position to {min(value, max(track.duration - 1, 0))}"
        elif action == "volume" and value is not None:
            self._muted_volume.pop(app, None)
            commands["volume"] = f"set sound volume to {min(max(value, 0), 100)}"
        elif action == "mute":
            if app in self._muted_volume:
                commands["mute"] = f"set sound volume to {self._muted_volume.pop(app)}"
            else:
                self._muted_volume[app] = track.volume or 50
                commands["mute"] = "set sound volume to 0"
        if action not in commands:
            return False, "unsupported"
        try:
            osascript(f'tell application "{app}"\n{commands[action]}\nend tell')
        except (RuntimeError, subprocess.SubprocessError) as error:
            log.info("%s %s failed: %s", app, action, error)
            return False, "failed"
        self.poll()
        return True, ""


# ----------------------------------------------------------------------------- connection

@dataclass
class ControlState:
    last_id: int = 0
    result: tuple[int, bool, str] = (0, False, "")
    queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=1))
    nfc_queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=4))


class ProtocolError(Exception):
    pass


async def receive(socket_, controls: ControlState, touched: list[float]) -> None:
    async for message in socket_:
        if isinstance(message, bytes):
            raise ProtocolError("binary frame from the display")
        frame = json.loads(message)
        if frame.get("type") == "buddy.control" and len(message.encode()) > 512:
            raise ProtocolError("oversized control frame")
        touched[0] = time.monotonic()
        if frame.get("type") == "buddy.ack":
            continue
        if frame.get("type") == "buddy.nfc" and frame.get("v") == 1:
            uid = nfc_albums.normalize_uid(str(frame.get("uid", "")))
            if uid:
                if controls.nfc_queue.full():
                    controls.nfc_queue.get_nowait()
                controls.nfc_queue.put_nowait(uid)
            continue
        if frame.get("type") == "buddy.control" and frame.get("v") == 1:
            control_id = frame.get("id")
            if not isinstance(control_id, int) or control_id <= controls.last_id:
                raise ProtocolError("control id went backwards")
            controls.last_id = control_id
            value = frame.get("value")
            if controls.queue.full():
                controls.queue.get_nowait()
            controls.queue.put_nowait((control_id, str(frame.get("action")), value if isinstance(value, int) else None))


async def nfc_worker(nfc: nfc_albums.NfcAlbums, controls: ControlState) -> None:
    while True:
        uid = await controls.nfc_queue.get()
        await asyncio.to_thread(nfc.handle_tap, uid)


async def control_worker(players: Players, amp, claude, controls: ControlState) -> None:
    while True:
        control_id, action, value = await controls.queue.get()
        if action == "focus":
            if value == 4:
                # "Show on PC" on the waiting alert: open that Amp thread in the browser.
                url = amp.waiting_thread_url() if amp else None
                ok, error = (subprocess.run(["open", url]).returncode == 0, "") if url else (False, "unavailable")
                if not ok and url:
                    error = "failed"
            elif value == 7 and claude:
                ok, error = await asyncio.to_thread(claude.focus_waiting)
            else:
                ok, error = False, "unavailable"
        else:
            ok, error = await asyncio.to_thread(players.execute, action, value)
        controls.result = (control_id, ok, error)
        log.info("display: %s%s -> %s", action, f" {value}" if value is not None else "", "ok" if ok else error)


async def session(device: str, host: str | None, stats: SystemStats, players: Players,
                  amp=None, claude=None, nfc=None) -> str:
    from websockets.asyncio.client import connect
    endpoint = await asyncio.to_thread(discover, device, host)
    if not endpoint:
        raise ConnectionError("display not found on this network")
    headers = {"Authorization": endpoint.sign("GET", "/monitor")}
    async with connect(f"ws://{endpoint.host}:{MONITOR_PORT}/monitor", additional_headers=headers,
                       proxy=None, ping_interval=None, max_size=4096, open_timeout=8,
                       compression=None) as ws:
        log.info("connected to ClawPal at %s", endpoint.host)
        controls, touched = ControlState(), [time.monotonic()]
        tasks = [asyncio.create_task(receive(ws, controls, touched)),
                 asyncio.create_task(control_worker(players, amp, claude, controls)),
                 asyncio.create_task(nfc_worker(nfc or nfc_albums.NfcAlbums(), controls)),
                 asyncio.create_task(asyncio.to_thread(log_nfc_health, device, endpoint.host))]
        art_sent, art_supported, art_retry, seq = 0, True, 0.0, 0
        art_task: asyncio.Task[int] | None = None
        try:
            while True:
                if tasks[0].done():
                    tasks[0].result()
                    raise ConnectionError("display closed the connection")
                seq += 1
                frame = {"type": "pc.stats", "v": 1, "seq": seq, "timestamp": int(time.time() * 1000),
                         **stats.sample(), "music": players.snapshot(controls.result), "auto_open_apps": False}
                if amp:
                    frame["codex"] = amp.snapshot()   # Amp threads fill the display's Codex page
                if claude and claude.active():
                    frame["claude"] = claude.snapshot()
                limit = CLAUDE_FRAME_LIMIT if "claude" in frame else FRAME_LIMIT
                payload = json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
                if len(payload.encode()) > limit:
                    frame["music"]["title"] = frame["music"]["title"][:40]
                    payload = json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
                await asyncio.wait_for(ws.send(payload), 4)
                if art_task is not None and art_task.done():
                    status = art_task.result()
                    art_task = None
                    if status in (404, 405):
                        art_supported = False
                    elif status != 200:
                        art_sent, art_retry = 0, time.monotonic() + 30
                cover = players.cover
                art_id = frame["music"]["art_id"]
                if (art_task is None and art_supported and cover and art_id == cover.id
                        and cover.id != art_sent and time.monotonic() >= art_retry):
                    art_sent = cover.id
                    art_task = asyncio.create_task(asyncio.to_thread(upload_cover, device, endpoint.host, cover))
                await asyncio.sleep(1)
                if time.monotonic() - touched[0] > 10:
                    raise ConnectionError("display stopped acknowledging")
        finally:
            if art_task is not None:
                tasks.append(art_task)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    return endpoint.host


def log_nfc_health(device: str, host: str) -> None:
    try:
        endpoint = discover(device, host, tries=2)
        if not endpoint:
            return
        status, body = pairing.signed_get(endpoint.host, TOKEN, endpoint.challenge, 1, "/health")
        if status != 200:
            return
        health = json.loads(body)
        nfc = health.get("nfc")
        if isinstance(nfc, dict):
            if nfc.get("detected"):
                log.info("NFC reader: detected at I2C 0x28 (VersionReg=0x%02x, last_uid=%s)",
                         int(nfc.get("version", 0)), nfc.get("last_uid") or "none")
            else:
                log.info("NFC reader: not detected on I2C 0x28 yet")
    except Exception as error:
        log.debug("health check failed: %s", error)


def upload_cover(device: str, host: str, cover: Cover) -> int:
    try:
        endpoint = discover(device, host)    # a fresh challenge, as the Windows app does
        if not endpoint:
            return 0
        status = signed_post(endpoint, "/art", cover.pixels,
                             {"X-ClawPal-Art-Id": str(cover.id), "X-ClawPal-Art-Size": str(COVER_SIZE)})
        log.info("album cover upload -> %s", status)
        return status
    except Exception as error:
        log.info("album cover upload failed: %s: %s", type(error).__name__, error)
        return 0


async def poll_players(players: Players) -> None:
    while True:
        try:
            await asyncio.to_thread(players.poll)
        except Exception as error:
            log.debug("player poll failed: %s", error)
        await asyncio.sleep(1)


AMP_CONFIG = pairing.HOME / "amp.json"


def load_amp() -> amp_threads.AmpThreads | amp_threads.AmpCli | None:
    if not AMP_CONFIG.exists():
        cli = amp_threads.find_amp_cli()
        if not cli:
            log.info("Amp threads: off (no amp CLI found, and amp-setup not run)")
            return None
        log.info("Amp threads: on, from the amp CLI at %s (no waiting state; see README)", cli)
        return amp_threads.AmpCli(cli)
    config = json.loads(AMP_CONFIG.read_text())
    secret = amp_threads.keychain_load(config["client_id"])
    if not secret:
        log.warning("Amp is set up but its secret isn't in the Keychain; run  amp-setup  again")
        return None
    log.info("Amp threads: on")
    return amp_threads.AmpThreads(AMP_CONFIG, secret)


async def poll_amp(amp) -> None:
    every = amp_threads.CLI_POLL_SECONDS if isinstance(amp, amp_threads.AmpCli) else amp_threads.POLL_SECONDS
    while True:
        await asyncio.to_thread(amp.poll)
        await asyncio.sleep(every)


def amp_setup() -> None:
    print("Amp threads on the display (fills its Codex page).\n"
          "You need an Amp M2M application with the amp.api:threads:read scope: a workspace admin\n"
          "creates one in the workspace's Applications settings, which also shows its token URL.\n")
    old = json.loads(AMP_CONFIG.read_text()) if AMP_CONFIG.exists() else {}
    def ask(label, key, default=""):
        value = input(f"{label} [{old.get(key, default)}]: ").strip()
        return value or old.get(key, default)
    config = {"token_url": ask("Token URL", "token_url"),
              "client_id": ask("Client ID", "client_id"),
              "api_base": ask("API base", "api_base", "https://ampcode.com/api/v2"),
              "user_email": ask("Only threads created by (your Amp email; blank for everyone's)", "user_email")}
    if not config["token_url"].startswith("https://") or not config["client_id"]:
        pairing.die("the token URL must be https:// and the client ID can't be empty")
    import getpass
    secret = getpass.getpass("Client secret (blank to keep the saved one): ") or amp_threads.keychain_load(config["client_id"])
    if not secret:
        pairing.die("no client secret")
    pairing.HOME.mkdir(parents=True, exist_ok=True)
    AMP_CONFIG.write_text(json.dumps(config, indent=2))
    amp = amp_threads.AmpThreads(AMP_CONFIG, secret)
    try:
        threads = amp.fetch()
    except Exception as error:
        pairing.die(f"Amp didn't accept that ({type(error).__name__}: {error}); nothing was saved to the Keychain")
    amp_threads.keychain_save(config["client_id"], secret)
    rows = amp_threads.pick_rows(threads, time.time())
    print(f"\nConnected: {len(threads)} threads updated in the last {amp_threads.WINDOW_HOURS} h. The display would show:")
    for row in rows:
        print(f"  [{row['state']:>11}]  {row['project'] or '(no project)'}: {row['title']}")
    if not rows:
        print("  (nothing recent)")
    print("\nRestart the companion (or the agent) to pick this up.")


async def run(host: str | None) -> None:
    global TOKEN
    if not pairing.CONFIG.exists():
        pairing.die("no pairing on this Mac; run  clawpal_mac.py install  first")
    config = json.loads(pairing.CONFIG.read_text())
    device = config.get("device_wifi_id") or config["device"]
    TOKEN = pairing.keychain_load(config["device"])
    host = host or config.get("last_ip")
    stats, players = SystemStats(), Players()
    poller = asyncio.create_task(poll_players(players))
    amp = load_amp()
    if amp:
        asyncio.create_task(poll_amp(amp))
    claude = claude_code.ClaudeCode()
    log.info("Claude Code: %s", "on (hooks installed)" if claude.active() else "off (run claude-setup to enable)")
    nfc = nfc_albums.NfcAlbums()
    retry = 1
    while True:
        try:
            host = await session(device, host, stats, players, amp, claude, nfc) or host
            retry = 1
        except Exception as error:   # any failure: wait, rediscover, reconnect
            log.warning("connection: %s: %s", type(error).__name__, error)
        await asyncio.sleep(retry)
        retry = min(retry * 2, 10)
    poller.cancel()


# ----------------------------------------------------------------------------- launchd

def agent_path() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{AGENT_LABEL}.plist"


def install_agent() -> None:
    script = Path(__file__).resolve()
    logs = pairing.HOME / "companion.log"
    plist = {"Label": AGENT_LABEL, "ProgramArguments": [sys.executable, str(script), "run"],
             "WorkingDirectory": str(script.parent), "RunAtLoad": True, "KeepAlive": True,
             "ProcessType": "Interactive", "StandardOutPath": str(logs), "StandardErrorPath": str(logs)}
    path = agent_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(path)], capture_output=True)
    path.write_bytes(plistlib.dumps(plist))
    result = subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(path)], capture_output=True, text=True)
    if result.returncode:
        pairing.die("launchctl couldn't start the agent: " + result.stderr.strip())
    print(f"The companion now starts at login. Log: {logs}")


def remove_agent() -> None:
    path = agent_path()
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(path)], capture_output=True)
    path.unlink(missing_ok=True)
    print("Removed; the companion no longer starts at login.")


def claude_setup() -> None:
    path = claude_code.install_bridge()
    print(f"Installed ClawPal hooks and status-line wrapper in {path}.")
    print(f"Original settings backup & prior status line saved under {claude_code.bridge_dir()}.")
    print("Restart any running Claude Code sessions to start reporting; run `claude-remove` to revert cleanly.")


def claude_remove() -> None:
    changed = claude_code.uninstall_bridge()
    if changed:
        print("Removed ClawPal's Claude Code hooks and restored your previous status line.")
    else:
        print("No ClawPal Claude Code hooks were present.")


def nfc_list() -> None:
    mapping = nfc_albums.load_mapping()
    if mapping:
        print(f"Mapped NFC cards ({nfc_albums.ALBUMS_FILE}):")
        for uid, entry in sorted(mapping.items()):
            print(f"  {uid}  [{entry.get('service', '?'):11}]  {entry.get('label') or entry.get('uri', '')}  ({entry.get('uri', '')})")
    else:
        print(f"No NFC cards mapped yet ({nfc_albums.ALBUMS_FILE}).")
    last = nfc_albums.read_last_tap()
    if last:
        age = max(int(time.time() - float(last.get("at", 0))), 0)
        print(f"\nLast tapped card: {last['uid']} ({age}s ago)")


def nfc_add(args) -> None:
    if args.uid.lower() == "last":
        last = nfc_albums.read_last_tap()
        if not last:
            pairing.die("no tapped card recorded yet; tap a card on the display first")
        uid = last["uid"]
    else:
        uid = nfc_albums.normalize_uid(args.uid)
        if not uid:
            pairing.die(f"invalid NFC UID {args.uid!r} (expected 8-20 hex digits)")

    if args.apple_music:
        entry = {"service": "apple_music", "uri": args.apple_music.strip(), "label": args.label or args.apple_music.strip()}
    else:
        if not args.target:
            pairing.die("pass a Spotify or Apple Music URL/URI, or use --apple-music '<Album or Playlist Name>'")
        uri = nfc_albums.normalize_spotify_uri(args.target)
        if uri:
            entry = {"service": "spotify", "uri": uri, "label": args.label or uri}
        else:
            am = nfc_albums.normalize_apple_music_url(args.target)
            if not am:
                pairing.die(f"unrecognized Spotify or Apple Music URL/URI: {args.target!r}")
            if args.label:
                am["label"] = args.label
            entry = am

    mapping = nfc_albums.load_mapping()
    mapping[uid] = entry
    nfc_albums.save_mapping(mapping)
    print(f"Mapped {uid} -> [{entry['service']}] {entry['label']} ({entry.get('url') or entry['uri']})")


def nfc_remove(args) -> None:
    uid = nfc_albums.normalize_uid(args.uid)
    if not uid:
        pairing.die(f"invalid NFC UID {args.uid!r}")
    mapping = nfc_albums.load_mapping()
    if uid not in mapping:
        print(f"Card {uid} is not mapped.")
        return
    mapping.pop(uid)
    nfc_albums.save_mapping(mapping)
    print(f"Removed NFC card {uid}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("run"); p.add_argument("--host", help="the display's IP, if broadcast discovery is blocked")
    p.add_argument("-v", "--verbose", action="store_true")
    sub.add_parser("install-agent"); sub.add_parser("remove-agent"); sub.add_parser("amp-setup")
    sub.add_parser("claude-setup"); sub.add_parser("claude-remove")
    sub.add_parser("nfc-list")
    p_add = sub.add_parser("nfc-add")
    p_add.add_argument("uid", help="card UID in hex (e.g. 04a1b2c3d4e580) or 'last'")
    p_add.add_argument("target", nargs="?", help="Spotify album/playlist/track URL or URI")
    p_add.add_argument("--apple-music", help="Apple Music album or playlist name")
    p_add.add_argument("--label", help="friendly display label for logs")
    p_rm = sub.add_parser("nfc-remove"); p_rm.add_argument("uid", help="card UID in hex")
    args = parser.parse_args()
    if args.command == "amp-setup":
        return amp_setup()
    if args.command == "claude-setup":
        return claude_setup()
    if args.command == "claude-remove":
        return claude_remove()
    if args.command == "nfc-list":
        return nfc_list()
    if args.command == "nfc-add":
        return nfc_add(args)
    if args.command == "nfc-remove":
        return nfc_remove(args)
    if args.command == "install-agent":
        return install_agent()
    if args.command == "remove-agent":
        return remove_agent()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("websockets").setLevel(logging.WARNING)
    try:
        asyncio.run(run(args.host))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
