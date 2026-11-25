#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

/* Callback fired once per card tap with the lowercase hex UID (8..20 chars, e.g. 14 chars for NTAG215/216). */
typedef void (*buddy_nfc_tap_cb_t)(const char *uid_hex);

/* Start the background polling task for an M5Stack RFID Unit 2 (WS1850S / MFRC522)
 * connected to the board's shared I2C bus (I2C_NUM_0, address 0x28). Safe if unplugged. */
esp_err_t buddy_nfc_start(buddy_nfc_tap_cb_t on_tap);

/* Thread-safe diagnostics for /health. */
void buddy_nfc_get_status(bool *detected, uint8_t *version, char *last_uid, size_t last_uid_size);
