#!/usr/bin/env python3
"""
Claude Code integration for ClawPal on macOS (display app 7).

Matches upstream v0.13.0 ClaudeContract.cs and ClaudeBridge.cs:
  - Reversible hooks + status-line wrapper in ~/.claude/settings.json
    (preserves all existing hooks and forwards stdin/stdout to any prior statusLine).
  - Session state files in ~/.clawpal-mac/claude/<sha256>.session.json.
  - Privacy: prompts, transcripts, tool inputs, credentials, and full paths are never stored or sent.
  - Invoked directly by Claude Code hooks (--claude-event) and statusLine (--claude-statusline).
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import re
import secrets
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

EVENTS = (
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Notification",
    "Stop",
    "StopFailure",
)

EVENT_MARKER = "--claude-event"
STATUSLINE_MARKER = "--claude-statusline"
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
MAX_SETTINGS_BYTES = 1_048_576
MAX_STDIN_BYTES = 1_048_576
MAX_SESSION_FILE_BYTES = 16_384
MAX_AGE_SECONDS = 31_536_000


def claude_dir() -> Path:
    custom = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    return Path(custom).expanduser().resolve() if custom else Path.home() / ".claude"


def bridge_dir() -> Path:
    return Path.home() / ".clawpal-mac" / "claude"


def limit_text(value: object, max_utf8_bytes: int) -> str:
    """Truncate to valid display UTF-8 fitting within max_utf8_bytes (upstream MusicContract.LimitText)."""
    if not isinstance(value, str) or not value:
        return ""
    out: list[str] = []
    used = 0
    for ch in value:
        cp = ord(ch)
        if cp < 32 or 0x7F <= cp <= 0x9F or cp in (0x2028, 0x2029) or 0xD800 <= cp <= 0xDFFF:
            ch = " "
        size = len(ch.encode("utf-8"))
        if used + size > max_utf8_bytes:
            break
        out.append(ch)
        used += size
    return "".join(out).strip()


def empty_window() -> dict:
    return {
        "available": False,
        "remaining_percent": 0.0,
        "window_minutes": 0,
        "reset_text": "",
        "resets_at": 0,
    }


def _parse_window(limits: dict, name: str, minutes: int, now: float) -> dict:
    window = limits.get(name)
    if not isinstance(window, dict):
        return empty_window()
    used = window.get("used_percentage")
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or used < 0 or used > 100:
        return empty_window()
    raw_reset = window.get("resets_at")
    if isinstance(raw_reset, bool):
        return empty_window()
    if isinstance(raw_reset, (int, float)) and math.isfinite(raw_reset):
        resets_at = int(raw_reset)
    elif isinstance(raw_reset, str) and raw_reset:
        try:
            from datetime import datetime
            resets_at = int(datetime.fromisoformat(raw_reset.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return empty_window()
    else:
        return empty_window()
    if resets_at <= int(now) or resets_at > 0xFFFFFFFF:
        return empty_window()
    return {
        "available": True,
        "remaining_percent": round(100.0 - float(used), 1),
        "window_minutes": minutes,
        "reset_text": "",
        "resets_at": resets_at,
    }


def _age_seconds(then: float, now: float) -> int:
    if then <= 0:
        return MAX_AGE_SECONDS
    return int(min(max(now - then, 0.0), MAX_AGE_SECONDS))


@dataclass
class ClaudeSession:
    id: str
    title: str
    project: str
    state: str
    seen: float
    activity_at: float
    process_id: int
    process_started: float
    ended: bool
    primary: dict
    secondary: dict
    usage_at: float

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "project": self.project,
            "state": self.state,
            "seen": self.seen,
            "activity_at": self.activity_at,
            "process_id": self.process_id,
            "process_started": self.process_started,
            "ended": self.ended,
            "primary": self.primary,
            "secondary": self.secondary,
            "usage_at": self.usage_at,
        }

    @classmethod
    def from_dict(cls, data: dict) -> ClaudeSession | None:
        if not isinstance(data, dict):
            return None
        sid = data.get("id")
        if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
            return None
        try:
            return cls(
                id=sid,
                title=limit_text(data.get("title", ""), 63),
                project=limit_text(data.get("project", ""), 31),
                state=str(data.get("state", "unknown")),
                seen=float(data.get("seen", 0.0)),
                activity_at=float(data.get("activity_at", 0.0)),
                process_id=int(data.get("process_id", 0)),
                process_started=float(data.get("process_started", 0.0)),
                ended=bool(data.get("ended", False)),
                primary=data.get("primary") if isinstance(data.get("primary"), dict) else empty_window(),
                secondary=data.get("secondary") if isinstance(data.get("secondary"), dict) else empty_window(),
                usage_at=float(data.get("usage_at", 0.0)),
            )
        except (TypeError, ValueError):
            return None


def observe(
    root: dict,
    status_line: bool,
    prior: ClaudeSession | None,
    now: float,
    process_id: int = 0,
    process_started: float = 0.0,
) -> ClaudeSession | None:
    """Port of upstream ClaudeContract.Observe."""
    if not isinstance(root, dict):
        return None
    sid = root.get("session_id")
    if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
        return None
    if prior is not None and prior.id != sid:
        prior = None

    kind = "statusline" if status_line else (root.get("hook_event_name") if isinstance(root.get("hook_event_name"), str) else "")
    notif = root.get("notification_type") if isinstance(root.get("notification_type"), str) else ""

    if kind == "SessionStart":
        state: str | None = "recent"
    elif kind in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        state = "working"
    elif kind == "PermissionRequest":
        state = "waiting"
    elif kind == "Stop":
        state = "completed"
    elif kind in ("StopFailure", "SessionEnd"):
        state = "interrupted"
    elif kind == "Notification" and notif in ("permission_prompt", "elicitation_dialog"):
        state = "waiting"
    elif kind == "Notification" and notif == "idle_prompt":
        state = "completed"
    elif kind == "statusline":
        state = prior.state if prior else "recent"
    else:
        state = None

    if state is None:
        return None

    raw_name = root.get("session_name") if isinstance(root.get("session_name"), str) else None
    title = limit_text(raw_name if raw_name is not None else (prior.title if prior else ""), 63)

    cwd = root.get("cwd") if isinstance(root.get("cwd"), str) else ""
    workspace = root.get("workspace")
    if isinstance(workspace, dict) and isinstance(workspace.get("project_dir"), str):
        cwd = workspace["project_dir"]
    leaf = cwd.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1] if cwd else ""
    project = limit_text(leaf, 31) or (prior.project if prior else "")

    primary = prior.primary if prior else empty_window()
    secondary = prior.secondary if prior else empty_window()
    usage_at = prior.usage_at if prior else 0.0

    if status_line:
        primary = empty_window()
        secondary = empty_window()
        limits = root.get("rate_limits")
        if isinstance(limits, dict):
            primary = _parse_window(limits, "five_hour", 300, now)
            secondary = _parse_window(limits, "seven_day", 10080, now)
        usage_at = now

    return ClaudeSession(
        id=sid,
        title=title,
        project=project,
        state=state,
        seen=now,
        activity_at=(prior.activity_at if (status_line and prior is not None) else now),
        process_id=process_id if process_id > 0 else (prior.process_id if prior else 0),
        process_started=process_started if process_id > 0 else (prior.process_started if prior else 0.0),
        ended=(kind == "SessionEnd"),
        primary=primary,
        secondary=secondary,
        usage_at=usage_at,
    )


def owner_process() -> tuple[int, float]:
    """Find the ancestor Claude Code process (PID + create_time) so crashed processes expire cleanly."""
    try:
        import psutil
        proc = psutil.Process(os.getpid())
        for depth, parent in enumerate(proc.parents()):
            if depth >= 8:
                break
            try:
                name = (parent.name() or "").lower()
                cmdline = parent.cmdline()
                exe_leaf = os.path.basename(cmdline[0]).lower() if cmdline else ""
                if name in ("claude", "node") or exe_leaf == "claude":
                    return parent.pid, float(parent.create_time())
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
    except Exception:
        pass
    return 0, 0.0


def is_alive(session: ClaudeSession, now: float | None = None) -> bool:
    current = time.time() if now is None else now
    if session.process_id <= 0:
        return (current - session.seen) < 90.0
    try:
        import psutil
        proc = psutil.Process(session.process_id)
        if not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE:
            return False
        return abs(float(proc.create_time()) - session.process_started) < 2.0
    except Exception:
        return False


def build_snapshot(
    source: list[ClaudeSession],
    now: float,
    alive_fn=is_alive,
) -> dict:
    """Port of upstream ClaudeContract.Snapshot -> firmware `claude` object."""
    sessions = [s for s in source if s.seen <= now + 60.0 and s.seen > now - 86400.0]
    sessions.sort(key=lambda s: s.seen, reverse=True)
    sessions = sessions[:32]

    alive_map = {s.id: (not s.ended and bool(alive_fn(s))) for s in sessions}
    live = [s for s in sessions if alive_map[s.id]]
    running = len(live) > 0

    usage = (live[0] if live else (sessions[0] if sessions else None))
    first = dict(usage.primary) if usage else empty_window()
    second = dict(usage.secondary) if usage else empty_window()
    if not first.get("available") or int(first.get("resets_at", 0)) <= int(now):
        first = empty_window()
    if not second.get("available") or int(second.get("resets_at", 0)) <= int(now):
        second = empty_window()

    available = bool(first["available"] or second["available"])
    age = _age_seconds(usage.usage_at, now) if (usage is not None and usage.usage_at > 0) else 0

    ordered = sorted(sessions, key=lambda s: (alive_map[s.id], s.activity_at), reverse=True)
    items = []
    for s in ordered:
        a = _age_seconds(s.activity_at, now)
        st = s.state
        if (st == "working" and a > 120) or (st == "waiting" and a > 1800) or (st in ("working", "waiting") and not alive_map[s.id]):
            st = "unknown"
        if st not in ("working", "completed", "interrupted", "recent", "unknown", "waiting"):
            st = "unknown"
        items.append({"title": limit_text(s.title, 63), "project": limit_text(s.project, 31), "state": st, "age_s": a})

    working = sum(1 for item in items if item["state"] == "working")
    activity = {
        "available": len(sessions) > 0,
        "stale": not running,
        "status": "local" if running else "closed",
        "age_s": 0,
        "working_count": min(working, 1000),
        "total_count": min(len(sessions), 1000),
        "items": items[:3],
    }
    return {
        "running": running,
        "available": available,
        "stale": available and (not running or age > 120),
        "status": "ready" if available else ("no_limits" if running else "closed"),
        "plan": "",
        "age_s": age,
        "primary": first,
        "secondary": second,
        "activity": activity,
    }


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def _strip_our_hooks(entries: list) -> None:
    for i in range(len(entries) - 1, -1, -1):
        entry = entries[i]
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            continue
        actions = entry["hooks"]
        for j in range(len(actions) - 1, -1, -1):
            action = actions[j]
            if isinstance(action, dict) and isinstance(action.get("command"), str) and EVENT_MARKER in action["command"]:
                actions.pop(j)
        if not actions:
            entries.pop(i)


def is_installed(claude_directory: Path | None = None) -> bool:
    cdir = claude_directory or claude_dir()
    path = cdir / "settings.json"
    if not path.exists():
        return False
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
        cmd = (settings.get("statusLine") or {}).get("command", "")
        return isinstance(cmd, str) and STATUSLINE_MARKER in cmd
    except Exception:
        return False


def install_bridge(
    claude_directory: Path | None = None,
    state_directory: Path | None = None,
    python_executable: str | None = None,
    script_path: Path | None = None,
) -> Path:
    """Reversibly install ClawPal hooks and statusLine wrapper into Claude Code settings.json."""
    cdir = claude_directory or claude_dir()
    bdir = state_directory or bridge_dir()
    py = python_executable or sys.executable
    script = (script_path or Path(__file__)).resolve()

    cdir.mkdir(parents=True, exist_ok=True)
    bdir.mkdir(parents=True, exist_ok=True)

    path = cdir / "settings.json"
    original = path.read_text(encoding="utf-8") if path.exists() else "{}"
    if len(original.encode("utf-8")) > MAX_SETTINGS_BYTES:
        raise ValueError("Claude settings.json is larger than 1 MiB")
    settings = json.loads(original)
    if not isinstance(settings, dict):
        raise ValueError("Claude settings.json root must be a JSON object")

    cmd_prefix = f"{shlex.quote(py)} {shlex.quote(str(script))}"

    status = settings.get("statusLine")
    if status is not None and not isinstance(status, dict):
        raise ValueError("Claude settings.json statusLine must be an object")

    ours = isinstance(status, dict) and isinstance(status.get("command"), str) and STATUSLINE_MARKER in status["command"]
    prev_path = bdir / "previous-statusline.json"
    if not ours:
        _atomic_write(prev_path, json.dumps(status, indent=2) if status is not None else "null")

    replacement = dict(status) if isinstance(status, dict) else {}
    replacement["type"] = "command"
    replacement["command"] = f"{cmd_prefix} {STATUSLINE_MARKER}"
    interval = 30
    req = replacement.get("refreshInterval")
    if isinstance(req, int) and not isinstance(req, bool) and req >= 1:
        interval = min(interval, req)
    replacement["refreshInterval"] = interval
    settings["statusLine"] = replacement

    hooks = settings.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        raise ValueError("Claude settings.json hooks must be an object")
    if hooks is None:
        hooks = {}
        settings["hooks"] = hooks

    for name in EVENTS:
        entries = hooks.get(name)
        if entries is not None and not isinstance(entries, list):
            raise ValueError(f"Claude settings.json hooks.{name} must be an array")
        if entries is None:
            entries = []
            hooks[name] = entries
        _strip_our_hooks(entries)
        entries.append({
            "hooks": [{
                "type": "command",
                "command": f"{cmd_prefix} {EVENT_MARKER}",
                "timeout": 3,
            }]
        })

    updated = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    if updated == original:
        return path

    backup_path = bdir / "settings-before-clawpal.json"
    if path.exists() and not backup_path.exists():
        _atomic_write(backup_path, original)

    if path.exists() and path.read_text(encoding="utf-8") != original:
        raise RuntimeError("Claude settings.json changed concurrently; refusing to overwrite")
    _atomic_write(path, updated)
    return path


def uninstall_bridge(
    claude_directory: Path | None = None,
    state_directory: Path | None = None,
) -> bool:
    """Remove only ClawPal hooks and restore the prior statusLine saved by install_bridge."""
    cdir = claude_directory or claude_dir()
    bdir = state_directory or bridge_dir()
    path = cdir / "settings.json"
    prev_path = bdir / "previous-statusline.json"
    changed = False

    if path.exists():
        original = path.read_text(encoding="utf-8")
        if len(original.encode("utf-8")) > MAX_SETTINGS_BYTES:
            raise ValueError("Claude settings.json is larger than 1 MiB")
        settings = json.loads(original)
        if not isinstance(settings, dict):
            raise ValueError("Claude settings.json root must be a JSON object")

        status = settings.get("statusLine")
        if isinstance(status, dict) and isinstance(status.get("command"), str) and STATUSLINE_MARKER in status["command"]:
            settings.pop("statusLine", None)
            if prev_path.exists():
                prev = json.loads(prev_path.read_text(encoding="utf-8"))
                if isinstance(prev, dict):
                    settings["statusLine"] = prev

        hooks = settings.get("hooks")
        if isinstance(hooks, dict):
            for name in EVENTS:
                entries = hooks.get(name)
                if not isinstance(entries, list):
                    continue
                _strip_our_hooks(entries)
                if not entries:
                    hooks.pop(name, None)
            if not hooks:
                settings.pop("hooks", None)

        updated = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
        if updated != original:
            if path.read_text(encoding="utf-8") != original:
                raise RuntimeError("Claude settings.json changed concurrently; refusing to overwrite")
            _atomic_write(path, updated)
            changed = True

    prev_path.unlink(missing_ok=True)
    return changed


def store_event(root: dict, status_line: bool, state_directory: Path | None = None, now: float | None = None) -> None:
    sid = root.get("session_id")
    if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
        return
    bdir = state_directory or bridge_dir()
    bdir.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(sid.encode("utf-8")).hexdigest()
    lock_path = bdir / f"{key}.lock"
    session_path = bdir / f"{key}.session.json"

    with open(lock_path, "a+", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            prior = None
            if session_path.exists() and session_path.stat().st_size < MAX_SESSION_FILE_BYTES:
                try:
                    prior = ClaudeSession.from_dict(json.loads(session_path.read_text(encoding="utf-8")))
                except Exception:
                    prior = None
            pid, started = owner_process()
            session = observe(root, status_line, prior, time.time() if now is None else now, pid, started)
            if session is not None:
                _atomic_write(session_path, json.dumps(session.to_dict(), separators=(",", ":")))
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def forward_statusline(raw_input: str, state_directory: Path | None = None, stdout=None) -> None:
    out = stdout if stdout is not None else sys.stdout
    bdir = state_directory or bridge_dir()
    prev_path = bdir / "previous-statusline.json"
    command = ""
    try:
        if prev_path.exists():
            saved = json.loads(prev_path.read_text(encoding="utf-8"))
            if isinstance(saved, dict) and isinstance(saved.get("command"), str):
                command = saved["command"]
    except Exception:
        command = ""

    if not command.strip():
        try:
            doc = json.loads(raw_input)
            model = doc.get("model") if isinstance(doc, dict) else None
            if isinstance(model, dict) and isinstance(model.get("display_name"), str):
                out.write(limit_text(model["display_name"], 63))
                out.flush()
        except Exception:
            pass
        return

    try:
        res = subprocess.run(
            ["/bin/sh", "-c", command],
            input=raw_input,
            capture_output=True,
            text=True,
            timeout=1.8,
        )
        if res.stdout:
            out.write(res.stdout)
            out.flush()
    except Exception:
        pass


def receive(status_line: bool, state_directory: Path | None = None, stdin=None, stdout=None) -> int:
    """Entrypoint called by Claude Code hooks and statusLine. Always returns 0."""
    inp = stdin if stdin is not None else sys.stdin
    raw = ""
    try:
        raw = inp.read(MAX_STDIN_BYTES + 1)
        if len(raw.encode("utf-8")) <= MAX_STDIN_BYTES and raw.strip():
            root = json.loads(raw)
            if isinstance(root, dict):
                store_event(root, status_line, state_directory=state_directory)
    except Exception:
        pass  # Never interrupt a Claude Code session.
    if status_line:
        forward_statusline(raw, state_directory=state_directory, stdout=stdout)
    return 0


def read_sessions(state_directory: Path | None = None, now: float | None = None) -> list[ClaudeSession]:
    bdir = state_directory or bridge_dir()
    if not bdir.exists():
        return []
    current = time.time() if now is None else now
    files = sorted(bdir.glob("*.session.json"), key=lambda p: p.stat().st_mtime, reverse=True)[:64]
    rows: list[ClaudeSession] = []
    for f in files:
        try:
            st = f.stat()
            if st.st_size > MAX_SESSION_FILE_BYTES:
                continue
            if current - st.st_mtime > 2 * 86400:
                f.unlink(missing_ok=True)
                f.with_name(f.name.replace(".session.json", ".lock")).unlink(missing_ok=True)
                continue
            session = ClaudeSession.from_dict(json.loads(f.read_text(encoding="utf-8")))
            if session is not None:
                rows.append(session)
        except Exception:
            continue
    return rows


def find_host_app_bundle(pid: int) -> str | None:
    """Walk ancestor processes on macOS to find the enclosing .app bundle (Terminal, Orca, VS Code, Claude, etc.)."""
    if pid <= 0:
        return None
    try:
        import psutil
        proc = psutil.Process(pid)
        for p in [proc, *proc.parents()]:
            try:
                exe = p.exe() or ""
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
            marker = ".app/Contents/MacOS/"
            idx = exe.find(marker)
            if idx != -1:
                return exe[:idx + 4]
    except Exception:
        return None
    return None


class ClaudeCode:
    """Companion-side reader for ~/.clawpal-mac/claude/ session files."""

    def __init__(self, state_directory: Path | None = None, claude_directory: Path | None = None) -> None:
        self.state_dir = state_directory or bridge_dir()
        self.claude_dir = claude_directory or claude_dir()

    def active(self) -> bool:
        """True once the bridge is installed or session files exist."""
        if is_installed(self.claude_dir):
            return True
        return self.state_dir.exists() and any(self.state_dir.glob("*.session.json"))

    def snapshot(self, now: float | None = None) -> dict:
        current = time.time() if now is None else now
        rows = read_sessions(self.state_dir, now=current)
        return build_snapshot(rows, current)

    def focus_waiting(self) -> tuple[bool, str]:
        """Bring forward the macOS app hosting a waiting Claude Code session (Show on PC, app 7)."""
        now = time.time()
        rows = read_sessions(self.state_dir, now=now)
        waiting = [
            s for s in rows
            if s.state == "waiting" and not s.ended and is_alive(s, now) and (now - s.activity_at) <= 1800
        ]
        waiting.sort(key=lambda s: s.activity_at, reverse=True)
        for session in waiting:
            app_bundle = find_host_app_bundle(session.process_id)
            if app_bundle:
                ok = subprocess.run(["open", "-a", app_bundle], capture_output=True).returncode == 0
                return (True, "") if ok else (False, "failed")
        return False, "unavailable"


if __name__ == "__main__":
    if EVENT_MARKER in sys.argv:
        sys.exit(receive(status_line=False))
    if STATUSLINE_MARKER in sys.argv:
        sys.exit(receive(status_line=True))
    print("Usage: claude_code.py [--claude-event | --claude-statusline]", file=sys.stderr)
    sys.exit(2)
