"""
Fake ClawPal v0.13.0 display for local tests.

Mirrors the firmware's validation rules from:
  - firmware/main/include/buddy_model.h
  - firmware/main/network/buddy_telemetry_parse.c
  - companion/Protocol.cs (UDP discovery, HMAC auth v2, /art upload, WS /monitor)
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import math
import secrets
import socket
import threading
from dataclasses import dataclass, field

DISCOVERY_PORT = 42170
MONITOR_PORT = 42171
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
MUSIC_MAX_SECONDS = 7 * 24 * 60 * 60
SHORTCUT_MAX_REV = 0xFFFF
SHORTCUT_MASK_MAX = (1 << 16) - 1

VALID_TASK_STATES = frozenset({"working", "completed", "interrupted", "recent", "unknown", "waiting"})
VALID_ACTIVITY_STATUSES = frozenset({"local", "partial", "waiting", "unavailable", "closed", "error"})


def valid_display_utf8(text: str) -> bool:
    for ch in text:
        cp = ord(ch)
        if cp < 32 or (0x7F <= cp <= 0x9F) or (0xD800 <= cp <= 0xDFFF) or cp in (0x2028, 0x2029):
            return False
    return True


def bounded_json(payload: bytes) -> bool:
    if b"\x00" in payload:
        return False
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        return False
    depth = 0
    in_string = False
    escaped = False
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if in_string:
            if escaped:
                if c == "u" and i + 4 < n and text[i + 1:i + 5].lower() == "0000":
                    return False
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c in "{[":
            depth += 1
            if depth > 8:
                return False
        elif c in "}]":
            if depth == 0:
                return False
            depth -= 1
        i += 1
    return not in_string and depth == 0


def _is_number(v: object) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _check_string(obj: dict, key: str, buf_size: int, *, required: bool = False) -> tuple[bool, str]:
    if key not in obj or obj[key] is None:
        if required:
            return False, f"missing required string {key}"
        return True, ""
    val = obj[key]
    if not isinstance(val, str):
        return False, f"{key} must be string"
    raw = val.encode("utf-8")
    if len(raw) >= buf_size:
        return False, f"{key} is {len(raw)} bytes (must be < {buf_size})"
    if not valid_display_utf8(val):
        return False, f"{key} contains invalid display characters"
    return True, ""


def _check_metric(obj: dict, key: str, lo: float, hi: float) -> tuple[bool, str]:
    if key not in obj or obj[key] is None:
        return True, ""
    val = obj[key]
    if not _is_number(val) or val < lo or val > hi:
        return False, f"{key}={val!r} out of [{lo}, {hi}]"
    return True, ""


def _check_uint64(obj: dict, key: str) -> tuple[bool, str]:
    if key not in obj or obj[key] is None:
        return False, f"missing uint64 {key}"
    val = obj[key]
    if not _is_number(val) or val < 0 or val > 9007199254740991 or math.floor(val) != val:
        return False, f"{key}={val!r} invalid uint64"
    return True, ""


def _check_bool(obj: dict, key: str, *, required: bool = False) -> tuple[bool, str]:
    if key not in obj:
        if required:
            return False, f"missing required bool {key}"
        return True, ""
    if not isinstance(obj[key], bool):
        return False, f"{key} must be bool"
    return True, ""


def _check_uint32(obj: dict, key: str, maximum: int, *, required: bool = False) -> tuple[bool, str]:
    if key not in obj:
        if required:
            return False, f"missing required uint32 {key}"
        return True, ""
    val = obj[key]
    if not _is_number(val) or val < 0 or val > maximum or math.floor(val) != val:
        return False, f"{key}={val!r} invalid uint32 (max {maximum})"
    return True, ""


def _check_music(root: dict) -> tuple[bool, str]:
    if "music" not in root or root["music"] is None:
        return True, ""
    m = root["music"]
    if not isinstance(m, dict):
        return False, "music must be object"
    for b in (
        "running", "available", "playing", "can_play_pause", "can_next", "can_previous",
        "control_ok", "can_shuffle", "shuffle", "can_repeat", "can_seek", "can_volume", "muted",
    ):
        ok, err = _check_bool(m, b)
        if not ok:
            return False, f"music.{err}"
    for s, sz in (("title", 192), ("artist", 128), ("album", 128), ("control_error", 32), ("source", 32)):
        ok, err = _check_string(m, s, sz)
        if not ok:
            return False, f"music.{err}"
    for u, mx in (
        ("position_s", MUSIC_MAX_SECONDS), ("duration_s", MUSIC_MAX_SECONDS),
        ("control_id", 0x7FFFFFFF), ("repeat", 2), ("volume", 100),
        ("art_color", 0xFFFFFF), ("art_id", 0x7FFFFFFF),
    ):
        ok, err = _check_uint32(m, u, mx)
        if not ok:
            return False, f"music.{err}"
    return True, ""


def _check_provider_window(provider: dict, key: str, prefix: str) -> tuple[bool, str]:
    if key not in provider or provider[key] is None:
        return True, ""
    w = provider[key]
    if not isinstance(w, dict):
        return False, f"{prefix}.{key} must be object"
    ok, err = _check_bool(w, "available", required=True)
    if not ok:
        return False, f"{prefix}.{key}.{err}"
    if "remaining_percent" not in w or not _is_number(w["remaining_percent"]):
        return False, f"{prefix}.{key}.remaining_percent must be number"
    ok, err = _check_metric(w, "remaining_percent", 0, 100)
    if not ok:
        return False, f"{prefix}.{key}.{err}"
    ok, err = _check_uint32(w, "window_minutes", 525600, required=True)
    if not ok:
        return False, f"{prefix}.{key}.{err}"
    ok, err = _check_string(w, "reset_text", 48, required=True)
    if not ok:
        return False, f"{prefix}.{key}.{err}"
    ok, err = _check_uint32(w, "resets_at", 0xFFFFFFFF)
    if not ok:
        return False, f"{prefix}.{key}.{err}"
    return True, ""


def _check_provider_task(item: object, prefix: str) -> tuple[bool, str]:
    if not isinstance(item, dict):
        return False, f"{prefix} must be object"
    for s, sz in (("title", 64), ("project", 32), ("state", 16)):
        ok, err = _check_string(item, s, sz, required=True)
        if not ok:
            return False, f"{prefix}.{err}"
    ok, err = _check_uint32(item, "age_s", 31536000, required=True)
    if not ok:
        return False, f"{prefix}.{err}"
    if item["state"] not in VALID_TASK_STATES:
        return False, f"{prefix}.state={item['state']!r} unknown"
    return True, ""


def _check_provider_activity(provider: dict, prefix: str) -> tuple[bool, str]:
    if "activity" not in provider or provider["activity"] is None:
        return True, ""
    a = provider["activity"]
    if not isinstance(a, dict):
        return False, f"{prefix}.activity must be object"
    for b in ("available", "stale"):
        ok, err = _check_bool(a, b, required=True)
        if not ok:
            return False, f"{prefix}.activity.{err}"
    ok, err = _check_string(a, "status", 24, required=True)
    if not ok:
        return False, f"{prefix}.activity.{err}"
    if a["status"] not in VALID_ACTIVITY_STATUSES:
        return False, f"{prefix}.activity.status={a['status']!r} unknown"
    for u, mx in (("age_s", 31536000), ("working_count", 1000), ("total_count", 1000)):
        ok, err = _check_uint32(a, u, mx, required=True)
        if not ok:
            return False, f"{prefix}.activity.{err}"
    items = a.get("items")
    if not isinstance(items, list):
        return False, f"{prefix}.activity.items must be array"
    if len(items) > 3:
        return False, f"{prefix}.activity.items has {len(items)} entries (max 3)"
    for idx, item in enumerate(items):
        ok, err = _check_provider_task(item, f"{prefix}.activity.items[{idx}]")
        if not ok:
            return False, err
    return True, ""


def _check_provider(root: dict, key: str) -> tuple[bool, str]:
    if key not in root or root[key] is None:
        return True, ""
    p = root[key]
    if not isinstance(p, dict):
        return False, f"{key} must be object"
    for b in ("running", "available", "stale"):
        ok, err = _check_bool(p, b, required=True)
        if not ok:
            return False, f"{key}.{err}"
    for s, sz in (("status", 24), ("plan", 32)):
        ok, err = _check_string(p, s, sz, required=True)
        if not ok:
            return False, f"{key}.{err}"
    ok, err = _check_uint32(p, "age_s", 31536000, required=True)
    if not ok:
        return False, f"{key}.{err}"
    for w in ("primary", "secondary"):
        ok, err = _check_provider_window(p, w, key)
        if not ok:
            return False, err
    return _check_provider_activity(p, key)


def validate_telemetry_frame(raw: bytes | str) -> tuple[bool, str]:
    """Exact mirror of buddy_telemetry_parse() plus the 4096 / 6144 byte frame limit."""
    payload = raw.encode("utf-8") if isinstance(raw, str) else raw
    if not bounded_json(payload):
        return False, "bounded_json rejected payload (NUL, invalid UTF-8, or nesting > 8)"
    try:
        root = json.loads(payload)
    except ValueError as err:
        return False, f"invalid JSON: {err}"
    if not isinstance(root, dict):
        return False, "root must be object"

    limit = 6144 if root.get("claude") is not None else 4096
    if len(payload) > limit:
        return False, f"frame is {len(payload)} bytes (limit {limit})"

    if root.get("type") != "pc.stats":
        return False, f"type={root.get('type')!r} != 'pc.stats'"
    if not _is_number(root.get("v")) or root["v"] != 1:
        return False, f"v={root.get('v')!r} != 1"
    for sec in ("cpu", "gpu", "memory", "network"):
        if not isinstance(root.get(sec), dict):
            return False, f"{sec} must be object"
    if "auto_open_apps" in root and not isinstance(root["auto_open_apps"], bool):
        return False, "auto_open_apps must be bool"
    ok, err = _check_bool(root, "away")
    if not ok:
        return False, err

    for obj, key, sz in (
        (root, "hostname", 64),
        (root["cpu"], "name", 96),
        (root["gpu"], "name", 96),
    ):
        ok, err = _check_string(obj, key, sz)
        if not ok:
            return False, err
    for key in ("seq", "timestamp", "uptime_s"):
        ok, err = _check_uint64(root, key)
        if not ok:
            return False, err

    for obj, key, lo, hi in (
        (root["cpu"], "usage", 0, 100),
        (root["cpu"], "temperature", -100, 200),
        (root["gpu"], "usage", 0, 100),
        (root["gpu"], "temperature", -100, 200),
        (root["gpu"], "vram_used_mb", 0, 1e9),
        (root["gpu"], "vram_total_mb", 0, 1e9),
        (root["memory"], "usage", 0, 100),
        (root["memory"], "used_mb", 0, 1e9),
        (root["memory"], "total_mb", 0, 1e9),
        (root["network"], "rx_bps", 0, 1e15),
        (root["network"], "tx_bps", 0, 1e15),
    ):
        ok, err = _check_metric(obj, key, lo, hi)
        if not ok:
            return False, err

    for check in (
        _check_music(root),
        _check_provider(root, "codex"),
        _check_provider(root, "claude"),
    ):
        if not check[0]:
            return check

    if "game" in root and root["game"] is not None:
        g = root["game"]
        if not isinstance(g, dict):
            return False, "game must be object"
        ok, err = _check_bool(g, "active")
        if not ok:
            return False, f"game.{err}"
        for s, sz in (("name", 96), ("status", 16)):
            ok, err = _check_string(g, s, sz)
            if not ok:
                return False, f"game.{err}"
        ok, err = _check_metric(g, "fps", 0, 2000)
        if not ok:
            return False, f"game.{err}"
        if g.get("active") and not g.get("name"):
            return False, "active game requires non-empty name"

    if "shortcuts" in root and root["shortcuts"] is not None:
        sc = root["shortcuts"]
        if not isinstance(sc, dict):
            return False, "shortcuts must be object"
        ok, err = _check_uint32(sc, "rev", SHORTCUT_MAX_REV, required=True)
        if not ok or sc["rev"] == 0:
            return False, f"shortcuts.{err or 'rev must be > 0'}"
        ok, err = _check_uint32(sc, "on", SHORTCUT_MASK_MAX)
        if not ok:
            return False, f"shortcuts.{err}"

    return True, ""


def verify_auth_header(token: str, method: str, path: str, body: bytes, header: str,
                       expected_challenge: str, last_counter: int) -> tuple[bool, int, str]:
    if not header.startswith("ClawPal-HMAC "):
        return False, last_counter, "missing ClawPal-HMAC prefix"
    parts = dict(kv.split("=", 1) for kv in header[len("ClawPal-HMAC "):].split(",") if "=" in kv)
    challenge = parts.get("c", "")
    sig = parts.get("s", "")
    try:
        counter = int(parts.get("n", "0"))
    except ValueError:
        return False, last_counter, "bad counter"
    if challenge != expected_challenge:
        return False, last_counter, "challenge mismatch"
    if counter <= last_counter:
        return False, last_counter, "counter did not increase"
    body_hash = hashlib.sha256(body).hexdigest()
    msg = f"clawpal-auth-v2\n{method}\n{path}\n{challenge}\n{counter}\n{body_hash}"
    expected = hmac.new(token.encode(), msg.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        return False, last_counter, "signature mismatch"
    return True, counter, ""


@dataclass
class MockDisplay:
    """In-process fake display speaking UDP discovery + signed HTTP/WS on ephemeral ports."""
    device_id: str = "aabbccddeeff"
    token: str = field(default_factory=lambda: secrets.token_hex(32))
    host: str = "127.0.0.1"
    udp_port: int = 0
    http_port: int = 0
    frames: list[dict] = field(default_factory=list)
    rejected: list[tuple[str, str]] = field(default_factory=list)
    art_uploads: list[tuple[int, int, bytes]] = field(default_factory=list)
    pending_controls: list[dict] = field(default_factory=list)
    _challenges: dict[str, int] = field(default_factory=dict)
    _stop: threading.Event = field(default_factory=threading.Event)

    def start(self) -> None:
        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._udp.bind((self.host, self.udp_port))
        self.udp_port = self._udp.getsockname()[1]
        self._udp.settimeout(0.1)

        self._loop = asyncio.new_event_loop()
        ready = threading.Event()

        def run_server() -> None:
            asyncio.set_event_loop(self._loop)
            self._loop.run_until_complete(self._start_ws(ready))
            self._loop.run_forever()

        self._ws_thread = threading.Thread(target=run_server, daemon=True)
        self._ws_thread.start()
        ready.wait(5)

        self._udp_thread = threading.Thread(target=self._udp_loop, daemon=True)
        self._udp_thread.start()

    def stop(self) -> None:
        self._stop.set()
        if hasattr(self, "_loop"):
            self._loop.call_soon_threadsafe(self._loop.stop)
        if hasattr(self, "_udp"):
            self._udp.close()

    def _udp_loop(self) -> None:
        while not self._stop.is_set():
            try:
                data, addr = self._udp.recvfrom(1024)
            except OSError:
                continue
            text = data.decode(errors="ignore").strip()
            if not text.startswith("BUDDYOS_DISCOVER_V1 "):
                continue
            nonce = text.split(" ", 1)[1]
            challenge = secrets.token_hex(16)
            self._challenges[challenge] = 0
            proof = hmac.new(
                self.token.encode(),
                f"{nonce}|{self.device_id}|{self.http_port}|{challenge}".encode(),
                hashlib.sha256,
            ).hexdigest()
            reply = json.dumps({
                "type": "buddy.hello",
                "v": 2,
                "id": self.device_id,
                "port": self.http_port,
                "nonce": nonce,
                "challenge": challenge,
                "proof": proof,
            }).encode()
            self._udp.sendto(reply, addr)

    async def _start_ws(self, ready: threading.Event) -> None:
        from websockets.asyncio.server import serve
        from websockets.datastructures import Headers
        from websockets.http11 import Response

        def process_request(connection, request):
            auth = request.headers.get("Authorization", "")
            path = request.path
            method = "GET" if path == "/monitor" else "POST"
            challenge = ""
            if auth.startswith("ClawPal-HMAC "):
                for kv in auth[len("ClawPal-HMAC "):].split(","):
                    if kv.startswith("c="):
                        challenge = kv[2:]
            last_n = self._challenges.get(challenge, -1)
            if path == "/monitor":
                ok, new_n, err = verify_auth_header(self.token, "GET", "/monitor", b"", auth, challenge, last_n)
                if not ok:
                    return Response(401, "Unauthorized", Headers(), err.encode())
                self._challenges[challenge] = new_n
                return None  # upgrade to WebSocket
            if path == "/firmware":
                ok, new_n, err = verify_auth_header(self.token, "GET", "/firmware", b"", auth, challenge, last_n)
                if not ok:
                    return Response(401, "Unauthorized", Headers(), err.encode())
                self._challenges[challenge] = new_n
                body = json.dumps({"board": "waveshare-esp32-s3-touch-lcd-4.3b", "version": "0.13.0",
                                   "partition": "ota_0", "confirmed": True}).encode()
                return Response(200, "OK", Headers([("Content-Type", "application/json")]), body)
            return Response(404, "Not Found", Headers(), b"")

        # Separate raw HTTP endpoint for POST /art (websockets' process_request doesn't read POST bodies)
        self._ws_server = await serve(self._handle_ws, self.host, self.http_port, process_request=process_request)
        self.http_port = self._ws_server.sockets[0].getsockname()[1]
        ready.set()

    async def _handle_ws(self, ws) -> None:
        from websockets.exceptions import ConnectionClosed
        try:
            async for message in ws:
                ok, err = validate_telemetry_frame(message)
                if not ok:
                    self.rejected.append((str(message), err))
                    continue
                frame = json.loads(message)
                self.frames.append(frame)
                await ws.send(json.dumps({"type": "buddy.ack", "v": 1, "seq": frame["seq"]}))
                while self.pending_controls:
                    ctrl = self.pending_controls.pop(0)
                    await ws.send(json.dumps(ctrl))
        except ConnectionClosed:
            pass
