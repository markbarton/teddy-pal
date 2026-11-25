#!/usr/bin/env python3
"""
clawpal_mac.py - install ClawPal on a Waveshare ESP32-S3-Touch-LCD-4.3B from a Mac.

This does the same job as the Windows ClawPal-Setup.exe installer, without Windows:

  prepare   Download the official v0.13.0 release, check its SHA-256, and pull out the
            four signed firmware parts for the 4.3B (bootloader, partition table, app,
            OTA data). Nothing from the .exe is ever run; it is only read as a zip.
  identify  Ask the board over USB what it is (must be an ESP32-S3 with 16 MB flash).
  backup    Copy the whole 16 MB flash to a file and verify it, so you can always go back.
  install   Generate a pairing token, save it in your macOS Keychain, build the settings
            (NVS) image with your Wi-Fi + location, flash everything, and verify it.
  discover  Find the display on your Wi-Fi, check its HMAC proof against the token in the
            Keychain, and make one signed request. This proves the Mac is paired.
  restore   Write a backup made by `backup` back to the board.

Requires: Python 3.10+, `pip3 install esptool` (version 5 or later), a USB-C data cable.
ClawPal is GPLv3 by MinimalPulse (github.com/Kaayoos/clawpal); this script is independent.
"""
from __future__ import annotations

import argparse, getpass, hashlib, hmac, io, json, os, re, secrets, socket, struct, subprocess
import sys, time, urllib.request, zipfile, zlib
from datetime import datetime
from pathlib import Path

VERSION = "0.13.0"
RELEASE = f"https://github.com/Kaayoos/clawpal/releases/download/v{VERSION}"
BOARD_ID = "waveshare-esp32-s3-touch-lcd-4.3b"
FLASH_BYTES = 16 * 1024 * 1024
NVS_OFFSET, NVS_SIZE = 0x9000, 0x6000
DISCOVERY_PORT, MONITOR_PORT = 42170, 42171
HOME = Path.home() / ".clawpal-mac"
PAYLOAD = HOME / f"payload-{VERSION}"
CONFIG = HOME / "config.json"
KEYCHAIN_SERVICE = "ClawPal pairing token"
THEMES = ["crab", "studio", "crabv2", "crastudio"]
ACCENTS = ["champagne", "sage", "ice", "silver", "rose", "lavender", "copper", "teal"]
LANGUAGES = ["en", "pl"]
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def die(message: str) -> None:
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------------------- prepare

def download(url: str) -> bytes:
    print(f"  downloading {url.rsplit('/', 1)[-1]} ...", flush=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def bundle_file(exe: bytes, wanted: str) -> bytes:
    """Read one file out of a .NET single-file bundle (format v6). Read-only; never executed."""
    marker = bytes.fromhex("8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae")
    at = exe.find(marker)
    if at < 8:
        die("this doesn't look like the ClawPal installer bundle")
    p = struct.unpack_from("<q", exe, at - 8)[0]

    def text(p: int) -> tuple[str, int]:
        n = shift = 0
        while True:
            b = exe[p]; p += 1; n |= (b & 0x7F) << shift; shift += 7
            if b < 0x80:
                return exe[p:p + n].decode(), p + n

    major, _minor, count = struct.unpack_from("<IIi", exe, p); p += 12
    _, p = text(p)
    if major >= 2:
        p += 40
    for _ in range(count):
        offset, size = struct.unpack_from("<qq", exe, p); p += 16
        compressed = 0
        if major >= 6:
            compressed = struct.unpack_from("<q", exe, p)[0]; p += 8
        p += 1
        path, p = text(p)
        if path == wanted:
            raw = exe[offset:offset + (compressed or size)]
            return zlib.decompress(raw, -15) if compressed else raw
    die(f"{wanted} isn't in the installer bundle")


def embedded_zip(dll: bytes) -> zipfile.ZipFile:
    end = dll.rfind(b"PK\x05\x06")
    cd_size, cd_offset = struct.unpack_from("<II", dll, end + 12)
    start = end - cd_size - cd_offset
    return zipfile.ZipFile(io.BytesIO(dll[start:end + 22]))


def cmd_prepare(_args) -> None:
    PAYLOAD.mkdir(parents=True, exist_ok=True)
    expected = download(f"{RELEASE}/ClawPal-Setup.exe.sha256").decode().split()[0].lower()
    exe = download(f"{RELEASE}/ClawPal-Setup.exe")
    if sha256(exe) != expected:
        die("ClawPal-Setup.exe doesn't match its published SHA-256; stopping")
    print("  installer SHA-256 matches the release")
    payload = embedded_zip(bundle_file(exe, "ClawPal.Companion.dll"))
    profile = json.loads(payload.read(f"boards/{BOARD_ID}.json"))
    if profile["Version"] != VERSION or profile["FlashBytes"] != FLASH_BYTES:
        die("unexpected board profile in this release")
    parts = []
    for part in profile["Parts"]:
        data = payload.read(part["File"])
        if sha256(data) != part["Sha256"].lower():
            die(f"{part['File']} fails its checksum")
        target = PAYLOAD / Path(part["File"]).name
        target.write_bytes(data)
        parts.append({"offset": part["Offset"], "file": target.name, "sha256": part["Sha256"].lower()})
    app = (PAYLOAD / "clawpal.bin").read_bytes()
    if not (len(app) % 4096 == 0 and app[-4096] == 0xE7 and app[-4095] == 0x02):
        die("the app image isn't signed; the display would stay dark")
    release = json.loads(download(f"{RELEASE}/clawpal-release.json"))
    published = next(b for b in release["boards"] if b["board"] == BOARD_ID)["firmware"]["sha256"]
    if published != sha256(app):
        die("the app image doesn't match the release manifest")
    (PAYLOAD / "parts.json").write_text(json.dumps(parts, indent=2))
    print(f"\nReady: ClawPal {VERSION} for the 4.3B, signed and checksummed, in {PAYLOAD}")
    for part in parts:
        print(f"  {part['offset']:>9}  {part['file']}")


# --------------------------------------------------------------------------- esptool

def esptool(port: str, *args: str, capture: bool = False) -> str:
    command = [sys.executable, "-m", "esptool", "--chip", "esp32s3", "--port", port,
               "--baud", "460800", "--connect-attempts", "3", *args]
    if capture:
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            die(f"esptool failed:\n{result.stdout}\n{result.stderr}")
        return result.stdout + result.stderr
    if subprocess.run(command).returncode:
        die("esptool failed (see above)")
    return ""


def check_esptool() -> None:
    try:
        import esptool  # noqa: F401
        major = int(esptool.__version__.split(".")[0])
    except Exception:
        die("esptool isn't installed: run  pip3 install --user 'esptool>=5'")
    if major < 5:
        die("this script uses esptool 5 syntax: run  pip3 install --user --upgrade 'esptool>=5'")


def identify(port: str) -> str:
    out = esptool(port, "flash-id", capture=True)
    if not re.search(r"ESP32-S3\b", out):
        die("the board on that port isn't an ESP32-S3")
    size = re.search(r"Detected flash size:\s*(\d+)\s*MB", out)
    if not size or int(size.group(1)) != 16:
        die("expected 16 MB flash (the 4.3B); found " + (size.group(0) if size else "unknown"))
    mac = re.search(r"MAC:\s*([0-9a-f:]{17})", out, re.I)
    if not mac:
        die("couldn't read the board's MAC address")
    return mac.group(1).replace(":", "").lower()


def cmd_identify(args) -> None:
    check_esptool()
    device = identify(args.port)
    print(f"\nESP32-S3, 16 MB flash, MAC {device}. USB can't see which screen is fitted,"
          " so check the board itself says ESP32-S3-Touch-LCD-4.3B.")


def cmd_backup(args) -> None:
    check_esptool()
    device = identify(args.port)
    folder = HOME / "backups" / device
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"flash-{datetime.now():%Y%m%d-%H%M%S}.bin"
    print(f"Reading all 16 MB to {target} (about 5-8 minutes; keep the cable in)...")
    esptool(args.port, "--after", "no-reset", "read-flash", "0", str(FLASH_BYTES), str(target))
    if target.stat().st_size != FLASH_BYTES:
        die("the backup is incomplete")
    print("Verifying the backup against the board...")
    esptool(args.port, "--before", "no-reset", "verify-flash", "0", str(target))
    os.chmod(target, 0o600)
    print(f"\nBackup verified: {target}\nKeep it private: it may hold Waveshare's demo Wi-Fi settings.")


def cmd_flash_fork(args) -> None:
    """Flash the locally built, signed 4.3B firmware fork WITHOUT touching NVS (Wi-Fi/pairing stay intact)."""
    check_esptool()
    fork_payload = Path(__file__).resolve().parent / "firmware-fork" / "payload"
    profile_path = fork_payload / "boards" / f"{BOARD_ID}.json"
    if not profile_path.exists():
        die(f"fork build not found at {profile_path}; build the firmware fork first")
    profile = json.loads(profile_path.read_text())
    if profile.get("FlashBytes") != FLASH_BYTES:
        die("unexpected board profile in firmware fork")
    parts = []
    for part in profile["Parts"]:
        file_path = fork_payload / part["File"]
        if not file_path.exists():
            die(f"missing firmware part: {file_path}")
        data = file_path.read_bytes()
        if sha256(data) != part["Sha256"].lower():
            die(f"{part['File']} fails its checksum")
        if file_path.name == "clawpal.bin":
            if not (len(data) % 4096 == 0 and data[-4096] == 0xE7 and data[-4095] == 0x02):
                die("the fork clawpal.bin isn't signed; the display would stay dark")
        parts.append((part["Offset"], file_path))

    device = identify(args.port)
    print(f"Found ESP32-S3 (MAC {device}). Flashing signed custom firmware (preserving NVS Wi-Fi + pairing)...")
    write = ["--before", "default-reset", "write-flash", "--flash-mode", "keep",
             "--flash-freq", "keep", "--flash-size", "keep"]
    verify = ["verify-flash"]
    for offset, file_path in parts:
        write += [offset, str(file_path)]
        verify += [offset, str(file_path)]
    esptool(args.port, *write)
    print("Verifying flashed firmware...")
    esptool(args.port, *verify)
    print("\nFlashed and verified. The display will reboot and rejoin Wi-Fi automatically.")


def cmd_restore(args) -> None:
    check_esptool()
    backup = Path(args.file)
    if backup.stat().st_size != FLASH_BYTES:
        die("that file isn't a full 16 MB backup")
    identify(args.port)
    esptool(args.port, "write-flash", "0", str(backup))
    print("Restored.")


# --------------------------------------------------------------------------- NVS image

def crc(data: bytes) -> int:
    # zlib.crc32(data, 0xffffffff), as ESP-IDF uses; same as ClawPal's NvsImage.Crc.
    return zlib.crc32(data, 0xFFFFFFFF)


def nvs_image(values: dict[str, str]) -> bytes:
    """Port of companion/NvsImage.cs: NVS v2, one active page of string entries in 'buddy'."""
    image = bytearray(b"\xff" * NVS_SIZE)
    struct.pack_into("<II", image, 0, 0xFFFFFFFE, 0)
    image[8] = 0xFE
    struct.pack_into("<I", image, 28, crc(bytes(image[4:28])))
    index = 0

    def header(key: str, ns: int, kind: int, span: int) -> bytearray:
        raw = key.encode()
        if len(raw) > 15 or "\0" in key:
            raise ValueError(f"bad key {key!r}")
        h = bytearray(b"\xff" * 32)
        h[0], h[1], h[2] = ns, kind, span
        h[8:24] = b"\0" * 16
        h[8:8 + len(raw)] = raw
        return h

    def append(h: bytearray, data: bytes | None = None) -> None:
        nonlocal index
        span = h[2]
        if index + span > 126:
            raise ValueError("settings are too large for one NVS page")
        struct.pack_into("<I", h, 4, crc(bytes(h[:4]) + bytes(h[8:])))
        image[64 + index * 32:96 + index * 32] = h
        if data:
            image[96 + index * 32:96 + index * 32 + len(data)] = data
        for _ in range(span):
            image[32 + index // 4] &= ~(1 << (index % 4 * 2)) & 0xFF
            index += 1

    ns = header("buddy", 0, 1, 1)
    ns[24] = 1
    append(ns)
    for key, value in values.items():
        if "\0" in value:
            raise ValueError("settings can't contain a NUL")
        data = (value + "\0").encode()
        h = header(key, 1, 0x21, 1 + (len(data) + 31) // 32)
        struct.pack_into("<H", h, 24, len(data))
        struct.pack_into("<I", h, 28, crc(data))
        append(h, data)
    return bytes(image)


# --------------------------------------------------------------------------- Keychain

def keychain_save(device: str, token: str) -> None:
    result = subprocess.run(["security", "add-generic-password", "-U", "-a", device, "-s",
                             KEYCHAIN_SERVICE, "-l", "ClawPal display " + device, "-w", token],
                            capture_output=True, text=True)
    if result.returncode:
        die("couldn't save the pairing token to the Keychain: " + result.stderr.strip())


def keychain_load(device: str) -> str:
    result = subprocess.run(["security", "find-generic-password", "-a", device, "-s",
                             KEYCHAIN_SERVICE, "-w"], capture_output=True, text=True)
    if result.returncode:
        die(f"no pairing token in the Keychain for {device}; run install first")
    return result.stdout.strip()


# --------------------------------------------------------------------------- install

def ask(prompt: str, default: str | None = None) -> str:
    value = input(f"{prompt}{f' [{default}]' if default else ''}: ").strip()
    return value or (default or "")


def cmd_install(args) -> None:
    check_esptool()
    parts_file = PAYLOAD / "parts.json"
    if not parts_file.exists():
        die("run  prepare  first")
    parts = json.loads(parts_file.read_text())
    for part in parts:
        if sha256((PAYLOAD / part["file"]).read_bytes()) != part["sha256"]:
            die(f"{part['file']} has changed since prepare; run prepare again")

    device = identify(args.port)
    print(f"Found ESP32-S3 (MAC {device}).")
    if ask("Is this a Waveshare ESP32-S3-Touch-LCD-4.3B? Type 4.3B to continue") != "4.3B":
        die("stopped; nothing was written")
    backups = list((HOME / "backups" / device).glob("flash-*.bin"))
    if not backups and ask("No backup of this board yet. Continue without one? (yes/no)", "no") != "yes":
        die("run  backup  first; nothing was written")

    print("\nWi-Fi (2.4 GHz only; the ESP32-S3 can't see 5 GHz networks)")
    ssid = ask("  Network name")
    password = getpass.getpass("  Password: ")
    if not ssid or len(ssid.encode()) > 32 or len(password.encode()) > 63:
        die("SSID must be 1-32 bytes and the password at most 63")
    print("Weather and clock")
    city = ask("  Place name for the weather", "London")
    latitude = float(ask("  Latitude", "51.507400"))
    longitude = float(ask("  Longitude", "-0.127800"))
    timezone = ask("  POSIX time zone", "GMT0BST,M3.5.0/1,M10.5.0")
    theme = ask(f"  Theme {THEMES}", THEMES[0])
    accent = ask(f"  Accent {ACCENTS}", ACCENTS[0])
    if (not city or len(city.encode()) > 63 or abs(latitude) > 90 or abs(longitude) > 180
            or not re.fullmatch(r"[A-Za-z0-9+,.:/<>-]{3,127}", timezone)
            or theme not in THEMES or accent not in ACCENTS):
        die("one of those settings isn't valid")

    token = secrets.token_hex(32)
    values = {"ssid": ssid, "password": password, "token": token, "setup_key": secrets.token_hex(8),
              "city": city, "latitude": f"{latitude:.6f}", "longitude": f"{longitude:.6f}",
              "timezone": timezone, "language": "en", "theme": theme, "accent": accent}
    image = nvs_image(values)

    # Like the Windows installer: save the pairing before writing, so a failed flash
    # can't leave a display whose token nobody has.
    keychain_save(device, token)
    HOME.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps({"device": device, "board": BOARD_ID, "version": VERSION,
                                  "city": city, "latitude": latitude, "longitude": longitude,
                                  "timezone": timezone, "paired": datetime.now().isoformat()}, indent=2))
    nvs_file = HOME / f"provision-{secrets.token_hex(4)}.bin"
    try:
        nvs_file.write_bytes(image)
        os.chmod(nvs_file, 0o600)
        print("\nInstalling ClawPal (about 20 seconds; keep the cable in)...")
        write = ["--before", "default-reset", "write-flash", "--flash-mode", "keep",
                 "--flash-freq", "keep", "--flash-size", "keep"]
        for part in parts:
            write += [part["offset"], str(PAYLOAD / part["file"])]
        write += [hex(NVS_OFFSET), str(nvs_file)]
        esptool(args.port, *write)
        print("Checking the installed firmware...")
        verify = ["verify-flash"]
        for part in parts:
            verify += [part["offset"], str(PAYLOAD / part["file"])]
        esptool(args.port, *verify)
    finally:
        nvs_file.unlink(missing_ok=True)   # it holds your Wi-Fi password
    print(f"\nInstalled. The display should restart and join '{ssid}'."
          "\nThe pairing token is in your Keychain (\"ClawPal pairing token\")."
          "\nGive it 30 seconds, then run:  python3 clawpal_mac.py discover")


# --------------------------------------------------------------------------- discover

def lan(address: str) -> bool:
    a = [int(x) for x in address.split(".")]
    return a[0] == 10 or (a[0] == 172 and 16 <= a[1] <= 31) or a[:2] == [192, 168] or a[:2] == [169, 254]


def signed_get(host: str, token: str, challenge: str, counter: int, path: str) -> tuple[int, bytes]:
    message = f"clawpal-auth-v2\nGET\n{path}\n{challenge}\n{counter}\n{EMPTY_SHA256}"
    signature = hmac.new(token.encode(), message.encode(), hashlib.sha256).hexdigest()
    request = urllib.request.Request(f"http://{host}:{MONITOR_PORT}{path}", headers={
        "Authorization": f"ClawPal-HMAC c={challenge},n={counter},s={signature}",
        "X-ClawPal-Body-SHA256": EMPTY_SHA256})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def cmd_discover(args) -> None:
    if not CONFIG.exists():
        die("no pairing on this Mac; run install first")
    config = json.loads(CONFIG.read_text())
    device = config["device"]
    token = keychain_load(device)
    nonce = secrets.token_hex(16)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(1.0)
    targets = ["255.255.255.255"] + ([args.host] if args.host else [])
    print("Looking for the display on the local network...")
    found = None
    for _ in range(args.tries):
        for target in targets:
            sock.sendto(f"BUDDYOS_DISCOVER_V1 {nonce}".encode(), (target, DISCOVERY_PORT))
        try:
            while True:
                payload, (sender, _) = sock.recvfrom(1024)
                if not lan(sender):
                    continue
                hello = json.loads(payload)
                if hello.get("type") != "buddy.hello" or hello.get("nonce") != nonce:
                    continue
                challenge = hello.get("challenge", "")
                expected = hmac.new(token.encode(), f"{nonce}|{hello['id']}|{MONITOR_PORT}|{challenge}".encode(),
                                    hashlib.sha256).hexdigest()
                if hello.get("v") == 2 and hmac.compare_digest(expected, hello.get("proof", "")):
                    found = (sender, hello)
                    break
                print(f"  {sender} answered but its proof doesn't match this Mac's token")
        except socket.timeout:
            pass
        if found:
            break
    if not found:
        die("no paired display answered. Is it on the same 2.4 GHz network, and is the Mac's"
            " firewall allowing Python? You can also pass --host <display IP> from your router.")
    host, hello = found
    print(f"  found ClawPal at {host} (id {hello['id']}), proof verified with your Keychain token")
    if hello["id"] != device:
        print(f"  note: it reports id {hello['id']}, USB reported {device}; updating the saved id")
        config["device_wifi_id"] = hello["id"]
    status, body = signed_get(host, token, hello["challenge"], 1, "/firmware")
    if status != 200:
        die(f"signed GET /firmware answered {status}: {body[:200]!r}")
    firmware = json.loads(body)
    print(f"  signed request OK: {firmware.get('board')} running {firmware.get('version')}"
          f" (slot {firmware.get('partition')}, confirmed={firmware.get('confirmed')})")
    config["last_ip"] = host
    CONFIG.write_text(json.dumps(config, indent=2))
    print("\nThe Mac is paired with the display. It will say the PC is offline until a"
          " companion starts sending stats; that's the next step.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare").set_defaults(run=cmd_prepare)
    for name, run in [("identify", cmd_identify), ("backup", cmd_backup), ("install", cmd_install), ("flash-fork", cmd_flash_fork)]:
        p = sub.add_parser(name); p.add_argument("--port", required=True, help="e.g. /dev/cu.usbmodem1101"); p.set_defaults(run=run)
    p = sub.add_parser("restore"); p.add_argument("--port", required=True); p.add_argument("file"); p.set_defaults(run=cmd_restore)
    p = sub.add_parser("discover"); p.add_argument("--host"); p.add_argument("--tries", type=int, default=5); p.set_defaults(run=cmd_discover)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
