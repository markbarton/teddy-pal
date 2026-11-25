# TeddyPal Firmware Patches (for `Kaayoos/clawpal` v0.13.0)

All firmware modifications in this folder are built on top of **[Kaayoos/clawpal](https://github.com/Kaayoos/clawpal)** (GPL-3.0, MinimalPulse), specifically release tag **`v0.13.0`** (commit `e179e0855c75eeee40a233585a966d7a9f84c49b`).

You **do not** need these firmware patches just to use the macOS companion app — the stock official ClawPal `v0.13.0` firmware works out of the box for system stats, Spotify/Apple Music controls + album art, Clock, Claude Code, and basic Amp threads.

Apply these patches if you want the custom display enhancements:

1. **`01-nfc-amp-weather.patch` + `nfc/buddy_nfc.{c,h}`**
   - **NFC Jukebox (M5Stack RFID Unit 2 / WS1850S on I2C `0x28`):** polls NTAG/MIFARE cards on GPIO8/9 and emits `{"type":"buddy.nfc","v":1,"uid":"..."}` over WebSocket.
   - **Live screen switcher (`POST /app`):** lets `ClawPalMac` switch the active page on the display remotely (used by the Menu Bar / Dashboard and NFC auto-switch to Media).
   - **Two-step Amp Need-You alert UI:** replaces the full-screen takeover with an unobtrusive flashing red corner badge (`● N`) that opens a responsive 1–8 card grid; tapping any card opens that exact thread in Amp on your Mac (`focus` `100..107`). Heap-allocates `buddy_stats_t` on the ESP32-S3 to avoid main-task stack overflow with 8 threads + 1-line prompts.
   - **Upgraded 800×440 Weather Clock:** full-color vector weather graphics (`buddy_weather_icon.c`), weather-dressed mascot, and a bottom live weather dashboard card (current conditions, H/L, Feels Like, Wind, Humidity, Rain mm, and a 4-slot 3-hourly forecast strip with rain bars).

2. **`02-teddy-quotes.patch` + `generate_cat_mascot.py` (Optional)**
   - Replaces the 8-bit crab mascot (all 13 animation states × 48 frames + small icon + Home quotes) with **Teddy**, an 8-bit fluffy orange Maine Coon cat!
   - You can also edit the palette in `generate_cat_mascot.py` to generate your own custom 8-bit pet.

---

## How to Build & Flash the Patched Firmware

### Prerequisites
- **[ESP-IDF v5.x](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/)** installed on your Mac (e.g. `~/esp/esp-idf`)
- Python 3.10+ with `Pillow` and `esptool>=5` (for mascot generation & flashing)
- A USB-C **data** cable connected to your Waveshare ESP32-S3-Touch-LCD-4.3B

### 1. Clone upstream `Kaayoos/clawpal` at `v0.13.0`

```bash
git clone --depth 1 --branch v0.13.0 https://github.com/Kaayoos/clawpal.git firmware-fork
```

### 2. Apply the patches

```bash
# Core enhancements (NFC, POST /app, Amp 8-card Need-You, Weather Clock):
./firmware-patches/apply.sh ./firmware-fork

# Or include Teddy the 8-bit orange cat mascot and/or your local Amp.app Puck icon:
./firmware-patches/apply.sh ./firmware-fork --teddy --amp-icon
```

### 3. Generate your own firmware signing key (one-time)

ClawPal verifies firmware binaries using an Ed25519 signing key. **Never commit your private `.pem` key to git** — keep it in `~/.clawpal-mac/`:

```bash
cd firmware-fork
mkdir -p ~/.clawpal-mac
python3 scripts/sign-firmware.py --init --key ~/.clawpal-mac/signing-key.pem
```

This creates `~/.clawpal-mac/signing-key.pem` (private, stays on your Mac) and updates `firmware/release-signing-key.sha256` inside your local `firmware-fork/` clone (the public digest compiled into the firmware).

### 4. Build the firmware

> **macOS tip:** If you have Homebrew's `cmake` or `python` in `/usr/local/bin` conflicting with ESP-IDF's environment, source ESP-IDF's `export.sh` cleanly first.

```bash
source ~/esp/esp-idf/export.sh
export CLAWPAL_SIGNING_KEY="$HOME/.clawpal-mac/signing-key.pem"
python3 scripts/build-firmware.py --board waveshare-esp32-s3-touch-lcd-4.3b
```

### 5. Flash onto your display (preserving Wi-Fi & pairing token)

Back in the root `teddy-pal` directory:

```bash
python3 clawpal_mac.py flash-fork --port /dev/cu.usbmodemXXXX
```

`flash-fork` flashes only the firmware partitions and preserves your NVS Wi-Fi credentials and pairing token.

---

## License

These patches modify and extend [Kaayoos/clawpal](https://github.com/Kaayoos/clawpal), which is licensed under **GNU GPL v3.0**. Accordingly, all files in `firmware-patches/` are also licensed under **GNU GPL v3.0**.
