"""
Amp threads for the ClawPal display, read from Amp's external API (ampcode.com/api/external).

The display has no Amp page, so Amp fills the Codex page's task list (three rows) and its
"waiting for you" alert. One row per project, most urgent first:

  awaiting_approval -> "waiting"      amber, raises the full-screen alert
  error             -> "interrupted"  amber
  working           -> "working"      pulsing accent
  idle, unread      -> "completed"
  idle, read        -> "recent"

Credentials: an Amp machine-to-machine (M2M) application with the amp.api:threads:read scope,
created by a workspace admin under the workspace's Applications settings. Its secret lives in
the macOS Keychain; ~/.clawpal-mac/amp.json holds the rest.
"""
from __future__ import annotations

import base64, json, logging, subprocess, threading, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("clawpal.amp")
KEYCHAIN_SERVICE = "ClawPal Amp client secret"
SCOPE = "amp.api:threads:read"
POLL_SECONDS = 15
WINDOW_HOURS = 24
STATE_ORDER = {"waiting": 0, "interrupted": 1, "working": 2, "completed": 3, "recent": 4}
NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def text(value: object, max_bytes: int) -> str:
    cleaned = "".join(ch for ch in str(value or "") if ord(ch) >= 32 and not 0x7F <= ord(ch) <= 0x9F
                      and ch not in "  ").strip()
    raw = cleaned.encode()
    return cleaned if len(raw) < max_bytes else raw[:max_bytes - 1].decode(errors="ignore")


def parse_time(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def project_name(thread: dict) -> str:
    for repo in thread.get("repositories") or []:
        url = str(repo.get("url") or "").rstrip("/")
        if url:
            name = url.rsplit("/", 1)[-1]
            return name[:-4] if name.endswith(".git") else name
        directory = str(repo.get("dir") or "").rstrip("/")
        if directory:
            return directory.rsplit("/", 1)[-1]
    return ""


def row_state(thread: dict) -> str:
    state = (thread.get("agentState") or {}).get("state")
    if state == "awaiting_approval":
        return "waiting"
    if state == "error":
        return "interrupted"
    if state == "working":
        return "working"
    return "completed" if thread.get("unread") else "recent"


def pick_rows(threads: list[dict], now: float) -> list[dict]:
    """At most one thread per project, most urgent first, newest first within a state; three rows."""
    candidates = []
    for thread in threads:
        if thread.get("archived") or thread.get("parentThreadID"):
            continue                     # sub-agent threads belong to their parent
        state = row_state(thread)
        agent = thread.get("agentState") or {}
        changed = parse_time(agent.get("updatedAt")) or parse_time(thread.get("updatedAt")) or now
        candidates.append((STATE_ORDER[state], -changed, state, changed, thread))
    candidates.sort(key=lambda c: (c[0], c[1]))
    # Other threads in the same project that also need you, shown as "+N" on its row.
    attention: dict[str, int] = {}
    for _, _, state, _, thread in candidates:
        if state in ("waiting", "interrupted"):
            key = project_name(thread) or thread["id"]
            attention[key] = attention.get(key, 0) + 1
    rows, seen = [], set()
    for _, _, state, changed, thread in candidates:
        project = project_name(thread) or thread["id"]
        if project in seen:
            continue
        seen.add(project)
        extra = attention.get(project, 0) - (1 if state in ("waiting", "interrupted") else 0)
        suffix = f" +{extra}" if extra > 0 else ""
        label = text(project_name(thread), 32 - len(suffix)) + suffix if project_name(thread) else ""
        rows.append({"title": text(thread.get("title") or "Untitled thread", 64),
                     "project": label, "state": state,
                     "age_s": 0 if state == "working" else int(min(max(now - changed, 0), 31535999)),
                     "_id": thread["id"]})
        if len(rows) == 3:
            break
    return rows


class AmpThreads:
    def __init__(self, config_path: Path, secret: str) -> None:
        self.config = json.loads(config_path.read_text())
        self.secret = secret
        self.base = self.config.get("api_base", "https://ampcode.com/api/v2").rstrip("/")
        self._token, self._token_until = "", 0.0
        self._lock = threading.Lock()
        self._rows: list[dict] = []
        self._counts = (0, 0)
        self._fetched_at = 0.0
        self._status = "local"
        self._backoff_until = 0.0

    # --- auth: OAuth 2.0 client credentials (RFC 6749 §4.4), client authenticated with HTTP Basic
    def token(self) -> str:
        if self._token and time.time() < self._token_until - 60:
            return self._token
        body = urllib.parse.urlencode({"grant_type": "client_credentials", "scope": SCOPE}).encode()
        basic = base64.b64encode(f"{self.config['client_id']}:{self.secret}".encode()).decode()
        request = urllib.request.Request(self.config["token_url"], data=body, method="POST", headers={
            "Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json"})
        with NO_PROXY.open(request, timeout=12) as response:
            grant = json.loads(response.read(65536))
        self._token = grant["access_token"]
        self._token_until = time.time() + float(grant.get("expires_in", 900))
        return self._token

    def fetch(self) -> list[dict]:
        after = datetime.fromtimestamp(time.time() - WINDOW_HOURS * 3600, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        query = {"limit": 50, "orderBy": "updatedAt", "sort": "DESC", "updatedAfter": after}
        if self.config.get("user_email"):
            query["userEmail"] = self.config["user_email"]
        request = urllib.request.Request(f"{self.base}/workspace/threads?{urllib.parse.urlencode(query)}",
                                         headers={"Authorization": f"Bearer {self.token()}", "Accept": "application/json"})
        try:
            with NO_PROXY.open(request, timeout=12) as response:
                return json.loads(response.read(2_000_000)).get("threads", [])
        except urllib.error.HTTPError as error:
            if error.code == 401:
                self._token = ""
            raise

    def poll(self) -> None:
        if time.time() < self._backoff_until:
            return
        try:
            threads = self.fetch()
        except urllib.error.HTTPError as error:
            wait = 300 if error.code == 429 else 60
            retry = error.headers.get("Retry-After") if error.headers else None
            if retry and retry.isdigit():
                wait = int(retry)
            self._backoff_until = time.time() + wait
            log.warning("Amp API answered %s; trying again in %ss", error.code, wait)
            with self._lock:
                self._status = "error"
            return
        except (OSError, ValueError, KeyError) as error:
            self._backoff_until = time.time() + 60
            log.warning("Amp API unreachable: %s", error)
            with self._lock:
                self._status = "error"
            return
        now = time.time()
        rows = pick_rows(threads, now)
        live = [t for t in threads if not t.get("archived") and not t.get("parentThreadID")]
        working = sum(1 for t in live if (t.get("agentState") or {}).get("state") == "working")
        with self._lock:
            self._rows, self._counts = rows, (min(working, 1000), min(len(live), 1000))
            self._fetched_at, self._status = now, "local"

    def snapshot(self) -> dict:
        with self._lock:
            rows, counts, fetched, status = list(self._rows), self._counts, self._fetched_at, self._status
        now = time.time()
        has_data = fetched > 0
        stale = has_data and (status == "error" or now - fetched > 120)
        if has_data and now - fetched > 1800:
            rows, has_data = [], False      # don't show a half-hour-old "waiting" as current
        age = int(min(max(now - fetched, 0), 31535999)) if has_data else 0
        items = [{k: v for k, v in row.items() if not k.startswith("_")} for row in rows] if has_data else []
        for item in items:
            if item["state"] != "working" or item["age_s"]:
                item["age_s"] = int(min(item["age_s"] + age, 31535999))
        return {"running": True, "available": False, "stale": False, "status": "no_limits", "plan": "Amp",
                "age_s": 0,
                "activity": {"available": has_data, "stale": stale,
                             "status": ("error" if status == "error" else "unavailable") if not has_data else "local",
                             "age_s": age, "working_count": counts[0] if has_data else 0,
                             "total_count": counts[1] if has_data else 0, "items": items}}

    def waiting_thread_url(self) -> str | None:
        with self._lock:
            for row in self._rows:
                if row["state"] == "waiting":
                    return f"https://ampcode.com/threads/{row['_id']}"
        return None


def keychain_save(account: str, secret: str) -> None:
    subprocess.run(["security", "add-generic-password", "-U", "-a", account, "-s", KEYCHAIN_SERVICE,
                    "-l", "ClawPal Amp client secret", "-w", secret], check=True, capture_output=True)


def keychain_load(account: str) -> str | None:
    result = subprocess.run(["security", "find-generic-password", "-a", account, "-s", KEYCHAIN_SERVICE, "-w"],
                            capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


# ----------------------------------------------------------------------------- CLI mode
# `amp threads list --json` uses your existing `amp login`. It gives id, title, updated, tree
# and messageCount, but no agent state, so rows can only be "working" (updated in the last two
# minutes) or "recent"; nothing is ever "waiting".

import os, shutil

CLI_POLL_SECONDS = 30
CLI_PLACES = ["~/.local/bin/amp", "~/.amp/bin/amp", "/opt/homebrew/bin/amp", "/usr/local/bin/amp"]


def find_amp_cli() -> str | None:
    found = shutil.which("amp")
    if found:
        return found
    for place in CLI_PLACES:
        path = os.path.expanduser(place)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def tree_project(tree: str) -> str:
    """The folder name, unless it's a runner's generic workspace folder."""
    name = str(tree or "").rstrip("/").rsplit("/", 1)[-1]
    return "" if name in ("", "workspace", "user", "home") else name


class AmpCli:
    def __init__(self, executable: str) -> None:
        self.executable = executable
        folder = os.path.dirname(os.path.realpath(executable))
        # launchd agents get a bare PATH; an npm-installed amp also needs node.
        self.env = dict(os.environ, PATH=os.pathsep.join(
            [os.path.dirname(executable), folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]))
        self._lock = threading.Lock()
        self._rows: list[dict] = []
        self._counts = (0, 0)
        self._fetched_at = 0.0
        self._status = "local"
        self._backoff_until = 0.0

    def fetch(self) -> list[dict]:
        result = subprocess.run([self.executable, "threads", "list", "--json"], capture_output=True,
                                text=True, timeout=45, env=self.env, stdin=subprocess.DEVNULL)
        if result.returncode:
            lines = (result.stderr or result.stdout).strip().splitlines()
            raise RuntimeError(lines[-1] if lines else f"amp exited with {result.returncode}")
        data = json.loads(result.stdout)
        return data if isinstance(data, list) else data.get("threads", [])

    def poll(self) -> None:
        if time.time() < self._backoff_until:
            return
        try:
            threads = self.fetch()
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            self._backoff_until = time.time() + 120
            log.warning("amp threads list failed: %s", error)
            with self._lock:
                self._status = "error"
            return
        now = time.time()
        recent = []
        for thread in threads:
            if not isinstance(thread, dict) or not thread.get("id") or thread.get("archived"):
                continue
            changed = parse_time(thread.get("updated") or thread.get("updatedAt"))
            if changed is None or now - changed > WINDOW_HOURS * 3600:
                continue
            recent.append((changed, thread))
        recent.sort(key=lambda pair: -pair[0])
        rows = []
        for changed, thread in recent[:3]:
            age = int(min(max(now - changed, 0), 31535999))
            rows.append({"title": text(thread.get("title") or "Untitled thread", 64),
                         "project": text(tree_project(thread.get("tree", "")), 32),
                         "state": "working" if age <= 120 else "recent", "age_s": age, "_id": thread["id"]})
        working = sum(1 for changed, _ in recent if now - changed <= 120)
        with self._lock:
            self._rows, self._counts = rows, (min(working, 1000), min(len(recent), 1000))
            self._fetched_at, self._status = now, "local"

    snapshot = AmpThreads.snapshot

    def waiting_thread_url(self) -> str | None:
        return None
