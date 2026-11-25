/*
 * WS1850S / MFRC522 I2C NFC reader driver for the M5Stack RFID Unit 2 (0x28),
 * sharing I2C_NUM_0 (GPIO8 SDA, GPIO9 SCL) with the 4.3B touch controller and CH422G.
 *
 * Reads ISO14443A 4-byte, 7-byte (NTAG215 / NTAG216), and 10-byte UIDs with
 * presence debouncing so leaving a card on the reader never double-triggers.
 */
#include "buddy_nfc.h"
#include "board_profile.h"

#include <stdio.h>
#include <string.h>

#include "driver/i2c.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "buddy_nfc";

#define NFC_I2C_PORT        I2C_NUM_0
#define NFC_I2C_ADDR        0x28
#define NFC_I2C_TIMEOUT_MS  50

/* MFRC522 / WS1850S register addresses (unshifted for I2C). */
#define REG_COMMAND         0x01
#define REG_COM_IEN         0x02
#define REG_COM_IRQ         0x04
#define REG_DIV_IRQ         0x05
#define REG_ERROR           0x06
#define REG_STATUS2         0x08
#define REG_FIFO_DATA       0x09
#define REG_FIFO_LEVEL      0x0A
#define REG_CONTROL         0x0C
#define REG_BIT_FRAMING     0x0D
#define REG_COLL            0x0E
#define REG_MODE            0x11
#define REG_TX_MODE         0x12
#define REG_RX_MODE         0x13
#define REG_TX_CONTROL      0x14
#define REG_TX_ASK          0x15
#define REG_MOD_WIDTH       0x24
#define REG_RF_CFG          0x26
#define REG_CRC_RESULT_H    0x21
#define REG_CRC_RESULT_L    0x22
#define REG_T_MODE          0x2A
#define REG_T_PRESCALER     0x2B
#define REG_T_RELOAD_H      0x2C
#define REG_T_RELOAD_L      0x2D
#define REG_VERSION         0x37

/* PCD commands */
#define PCD_IDLE            0x00
#define PCD_CALC_CRC        0x03
#define PCD_TRANSCEIVE      0x0C
#define PCD_SOFT_RESET      0x0F

/* PICC commands (ISO14443A) */
#define PICC_CMD_REQA       0x26
#define PICC_CMD_WUPA       0x52
#define PICC_CMD_CT         0x88
#define PICC_CMD_SEL_CL1    0x93
#define PICC_CMD_SEL_CL2    0x95
#define PICC_CMD_SEL_CL3    0x97
#define PICC_CMD_HLTA       0x50

static portMUX_TYPE status_lock = portMUX_INITIALIZER_UNLOCKED;
static bool nfc_detected;
static uint8_t nfc_version;
static char nfc_last_uid[24];
static buddy_nfc_tap_cb_t tap_callback;

static esp_err_t write_reg(uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = {reg, val};
    return i2c_master_write_to_device(NFC_I2C_PORT, NFC_I2C_ADDR, buf, sizeof(buf),
                                      pdMS_TO_TICKS(NFC_I2C_TIMEOUT_MS));
}

static esp_err_t read_reg(uint8_t reg, uint8_t *val)
{
    return i2c_master_write_read_device(NFC_I2C_PORT, NFC_I2C_ADDR, &reg, 1, val, 1,
                                        pdMS_TO_TICKS(NFC_I2C_TIMEOUT_MS));
}

static esp_err_t write_fifo(const uint8_t *data, size_t len)
{
    if (len == 0 || len > 32) return ESP_ERR_INVALID_ARG;
    uint8_t buf[33];
    buf[0] = REG_FIFO_DATA;
    memcpy(buf + 1, data, len);
    return i2c_master_write_to_device(NFC_I2C_PORT, NFC_I2C_ADDR, buf, len + 1,
                                      pdMS_TO_TICKS(NFC_I2C_TIMEOUT_MS));
}

static esp_err_t read_fifo(uint8_t *out, size_t len)
{
    for (size_t i = 0; i < len; ++i) {
        esp_err_t err = read_reg(REG_FIFO_DATA, &out[i]);
        if (err != ESP_OK) return err;
    }
    return ESP_OK;
}

static esp_err_t set_bit_mask(uint8_t reg, uint8_t mask)
{
    uint8_t v = 0;
    esp_err_t err = read_reg(reg, &v);
    if (err != ESP_OK) return err;
    return write_reg(reg, v | mask);
}

static esp_err_t clear_bit_mask(uint8_t reg, uint8_t mask)
{
    uint8_t v = 0;
    esp_err_t err = read_reg(reg, &v);
    if (err != ESP_OK) return err;
    return write_reg(reg, v & (uint8_t)~mask);
}

static esp_err_t pcd_init(uint8_t *version_out)
{
    uint8_t ver = 0;
    esp_err_t err = read_reg(REG_VERSION, &ver);
    if (err != ESP_OK) return err;
    if (ver == 0x00 || ver == 0xFF) return ESP_ERR_NOT_FOUND;

    /* Soft reset */
    err = write_reg(REG_COMMAND, PCD_SOFT_RESET);
    if (err != ESP_OK) return err;
    vTaskDelay(pdMS_TO_TICKS(50));

    /* Wait until PowerDown bit clears (up to 100 ms) */
    for (int i = 0; i < 10; ++i) {
        uint8_t cmd = 0;
        if (read_reg(REG_COMMAND, &cmd) == ESP_OK && (cmd & (1U << 4)) == 0) break;
        vTaskDelay(pdMS_TO_TICKS(10));
    }

    /* Reset baud rates and ModWidth */
    if ((err = write_reg(REG_TX_MODE, 0x00)) != ESP_OK) return err;
    if ((err = write_reg(REG_RX_MODE, 0x00)) != ESP_OK) return err;
    if ((err = write_reg(REG_MOD_WIDTH, 0x26)) != ESP_OK) return err;

    /* Timer: f_timer = 13.56MHz / (2*169 + 1) = 40 kHz; reload 1000 => 25 ms */
    if ((err = write_reg(REG_T_MODE, 0x80)) != ESP_OK) return err;
    if ((err = write_reg(REG_T_PRESCALER, 0xA9)) != ESP_OK) return err;
    if ((err = write_reg(REG_T_RELOAD_H, 0x03)) != ESP_OK) return err;
    if ((err = write_reg(REG_T_RELOAD_L, 0xE8)) != ESP_OK) return err;

    /* 100% ASK modulation (ISO14443A), CRC preset 0x6363, max receiver gain (48 dB) */
    if ((err = write_reg(REG_TX_ASK, 0x40)) != ESP_OK) return err;
    if ((err = write_reg(REG_MODE, 0x3D)) != ESP_OK) return err;
    if ((err = write_reg(REG_RF_CFG, 0x70)) != ESP_OK) return err;

    /* Turn antenna on */
    if ((err = set_bit_mask(REG_TX_CONTROL, 0x03)) != ESP_OK) return err;

    if (version_out) *version_out = ver;
    return ESP_OK;
}

static esp_err_t pcd_calc_crc(const uint8_t *data, size_t len, uint8_t crc_out[2])
{
    esp_err_t err;
    if ((err = write_reg(REG_COMMAND, PCD_IDLE)) != ESP_OK) return err;
    if ((err = write_reg(REG_DIV_IRQ, 0x04)) != ESP_OK) return err;
    if ((err = write_reg(REG_FIFO_LEVEL, 0x80)) != ESP_OK) return err;
    if ((err = write_fifo(data, len)) != ESP_OK) return err;
    if ((err = write_reg(REG_COMMAND, PCD_CALC_CRC)) != ESP_OK) return err;

    for (int i = 0; i < 40; ++i) {
        uint8_t irq = 0;
        if ((err = read_reg(REG_DIV_IRQ, &irq)) != ESP_OK) return err;
        if (irq & 0x04) {
            write_reg(REG_COMMAND, PCD_IDLE);
            if ((err = read_reg(REG_CRC_RESULT_L, &crc_out[0])) != ESP_OK) return err;
            if ((err = read_reg(REG_CRC_RESULT_H, &crc_out[1])) != ESP_OK) return err;
            return ESP_OK;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    write_reg(REG_COMMAND, PCD_IDLE);
    return ESP_ERR_TIMEOUT;
}

/* Returns ESP_OK on valid response, ESP_ERR_TIMEOUT if no card answered,
 * ESP_FAIL on RF/protocol error, or I2C error code on bus failure. */
static esp_err_t pcd_transceive(const uint8_t *tx, size_t tx_len,
                                uint8_t *rx, size_t *rx_len,
                                uint8_t tx_last_bits, uint8_t *rx_last_bits)
{
    esp_err_t err;
    if ((err = write_reg(REG_COMMAND, PCD_IDLE)) != ESP_OK) return err;
    if ((err = write_reg(REG_COM_IRQ, 0x7F)) != ESP_OK) return err;       /* Clear all IRQ bits */
    if ((err = write_reg(REG_FIFO_LEVEL, 0x80)) != ESP_OK) return err;    /* Flush FIFO */
    if ((err = write_fifo(tx, tx_len)) != ESP_OK) return err;
    if ((err = write_reg(REG_BIT_FRAMING, tx_last_bits & 0x07)) != ESP_OK) return err;
    if ((err = write_reg(REG_COMMAND, PCD_TRANSCEIVE)) != ESP_OK) return err;
    if ((err = set_bit_mask(REG_BIT_FRAMING, 0x80)) != ESP_OK) return err; /* StartSend */

    uint8_t irq = 0;
    bool finished = false;
    for (int i = 0; i < 35; ++i) {
        if ((err = read_reg(REG_COM_IRQ, &irq)) != ESP_OK) return err;
        if (irq & 0x30) { /* RxIRq or IdleIRq */
            finished = true;
            break;
        }
        if (irq & 0x01) { /* TimerIRq: no card responded */
            clear_bit_mask(REG_BIT_FRAMING, 0x80);
            return ESP_ERR_TIMEOUT;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    clear_bit_mask(REG_BIT_FRAMING, 0x80);
    if (!finished) return ESP_ERR_TIMEOUT;

    uint8_t error_reg = 0;
    if ((err = read_reg(REG_ERROR, &error_reg)) != ESP_OK) return err;
    if (error_reg & 0x1B) { /* BufferOvfl | CollErr | ParityErr | ProtocolErr */
        return ESP_FAIL;
    }

    if (rx && rx_len) {
        uint8_t n = 0;
        if ((err = read_reg(REG_FIFO_LEVEL, &n)) != ESP_OK) return err;
        if (n > *rx_len) return ESP_ERR_NO_MEM;
        *rx_len = n;
        if (n > 0 && (err = read_fifo(rx, n)) != ESP_OK) return err;
        if (rx_last_bits) {
            uint8_t ctrl = 0;
            if ((err = read_reg(REG_CONTROL, &ctrl)) != ESP_OK) return err;
            *rx_last_bits = ctrl & 0x07;
        }
    }
    return ESP_OK;
}

static void picc_halt(void)
{
    uint8_t cmd[4] = {PICC_CMD_HLTA, 0x00, 0x00, 0x00};
    if (pcd_calc_crc(cmd, 2, &cmd[2]) == ESP_OK) {
        /* ISO14443A: HLTA expects NO response (timeout == success). */
        pcd_transceive(cmd, sizeof(cmd), NULL, NULL, 0, NULL);
    }
}

/* Poll for an ISO14443A card and read its full UID (4, 7, or 10 bytes).
 * Returns ESP_OK if a card was read, ESP_ERR_TIMEOUT if no card is present,
 * or another error if the bus/RF failed. */
static esp_err_t picc_read_uid(uint8_t uid_out[10], size_t *uid_len_out, bool *bus_error)
{
    *bus_error = false;
    /* Clear Crypto1On just in case, and clear valuesAfterColl */
    esp_err_t err = clear_bit_mask(REG_STATUS2, 0x08);
    if (err != ESP_OK) { *bus_error = true; return err; }
    err = clear_bit_mask(REG_COLL, 0x80);
    if (err != ESP_OK) { *bus_error = true; return err; }

    /* WUPA wakes both idle and halted cards, enabling reliable presence detection. */
    uint8_t wupa = PICC_CMD_WUPA;
    uint8_t atqa[4] = {0};
    size_t atqa_len = sizeof(atqa);
    uint8_t valid_bits = 0;
    err = pcd_transceive(&wupa, 1, atqa, &atqa_len, 7, &valid_bits);
    if (err == ESP_ERR_TIMEOUT) return ESP_ERR_TIMEOUT;
    if (err != ESP_OK) {
        if (err != ESP_FAIL) *bus_error = true;
        return err;
    }
    if (atqa_len != 2 || valid_bits != 0) return ESP_FAIL;

    static const uint8_t cascade_cmds[3] = {PICC_CMD_SEL_CL1, PICC_CMD_SEL_CL2, PICC_CMD_SEL_CL3};
    size_t uid_len = 0;

    for (int level = 0; level < 3; ++level) {
        uint8_t anticoll[2] = {cascade_cmds[level], 0x20};
        uint8_t resp[8] = {0};
        size_t resp_len = sizeof(resp);
        err = pcd_transceive(anticoll, sizeof(anticoll), resp, &resp_len, 0, &valid_bits);
        if (err != ESP_OK || resp_len != 5 || valid_bits != 0) return ESP_FAIL;

        uint8_t bcc = resp[0] ^ resp[1] ^ resp[2] ^ resp[3];
        if (bcc != resp[4]) return ESP_FAIL;

        /* SELECT with hardware CRC_A */
        uint8_t sel[9];
        sel[0] = cascade_cmds[level];
        sel[1] = 0x70;
        memcpy(&sel[2], resp, 5);
        if (pcd_calc_crc(sel, 7, &sel[7]) != ESP_OK) return ESP_FAIL;

        uint8_t sak_buf[4] = {0};
        size_t sak_len = sizeof(sak_buf);
        err = pcd_transceive(sel, sizeof(sel), sak_buf, &sak_len, 0, &valid_bits);
        if (err != ESP_OK || sak_len != 3 || valid_bits != 0) return ESP_FAIL;

        if (resp[0] == PICC_CMD_CT) {
            if (uid_len + 3 > 10) return ESP_FAIL;
            uid_out[uid_len++] = resp[1];
            uid_out[uid_len++] = resp[2];
            uid_out[uid_len++] = resp[3];
        } else {
            if (uid_len + 4 > 10) return ESP_FAIL;
            uid_out[uid_len++] = resp[0];
            uid_out[uid_len++] = resp[1];
            uid_out[uid_len++] = resp[2];
            uid_out[uid_len++] = resp[3];
        }

        /* SAK bit 2 == 0 means UID is complete! */
        if ((sak_buf[0] & 0x04) == 0) {
            picc_halt();
            *uid_len_out = uid_len;
            return ESP_OK;
        }
    }

    return ESP_FAIL;
}

static void nfc_task(void *argument)
{
    (void)argument;
    bool ready = false;
    int bus_errors = 0;
    char active_uid[24] = "";
    int absent_polls = 0;

    /* Give board & Wi-Fi a moment to settle before probing the shared I2C bus. */
    vTaskDelay(pdMS_TO_TICKS(1000));

    for (;;) {
        if (!ready) {
            uint8_t ver = 0;
            if (pcd_init(&ver) == ESP_OK) {
                ready = true;
                bus_errors = 0;
                taskENTER_CRITICAL(&status_lock);
                nfc_detected = true;
                nfc_version = ver;
                taskEXIT_CRITICAL(&status_lock);
                ESP_LOGI(TAG, "WS1850S/MFRC522 ready at I2C 0x%02X (VersionReg=0x%02X)", NFC_I2C_ADDR, ver);
            } else {
                taskENTER_CRITICAL(&status_lock);
                nfc_detected = false;
                nfc_version = 0;
                taskEXIT_CRITICAL(&status_lock);
                vTaskDelay(pdMS_TO_TICKS(5000));
                continue;
            }
        }

        uint8_t uid[10] = {0};
        size_t uid_len = 0;
        bool bus_error = false;
        esp_err_t err = picc_read_uid(uid, &uid_len, &bus_error);

        if (err == ESP_OK && uid_len >= 4 && uid_len <= 10) {
            bus_errors = 0;
            absent_polls = 0;
            char hex[24] = "";
            for (size_t i = 0; i < uid_len; ++i) {
                snprintf(hex + i * 2, sizeof(hex) - i * 2, "%02x", uid[i]);
            }
            if (strcmp(hex, active_uid) != 0) {
                strlcpy(active_uid, hex, sizeof(active_uid));
                taskENTER_CRITICAL(&status_lock);
                strlcpy(nfc_last_uid, hex, sizeof(nfc_last_uid));
                taskEXIT_CRITICAL(&status_lock);
                ESP_LOGI(TAG, "NFC card tapped: %s (%u bytes)", hex, (unsigned)uid_len);
                if (tap_callback) {
                    tap_callback(hex);
                }
            }
        } else if (bus_error) {
            if (++bus_errors >= 10) {
                ESP_LOGW(TAG, "NFC reader I2C errors; will re-probe");
                ready = false;
                active_uid[0] = '\0';
                absent_polls = 0;
            }
        } else {
            bus_errors = 0;
            if (active_uid[0] != '\0') {
                if (++absent_polls >= 6) { /* ~1.2s without card => allow re-tapping same card */
                    active_uid[0] = '\0';
                    absent_polls = 0;
                }
            }
        }

        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

esp_err_t buddy_nfc_start(buddy_nfc_tap_cb_t on_tap)
{
#if defined(CLAWPAL_DRIVER_WAVESHARE_RGB)
    tap_callback = on_tap;
    if (xTaskCreate(nfc_task, "buddy_nfc", 4096, NULL, 2, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
#else
    (void)on_tap;
    return ESP_OK;
#endif
}

void buddy_nfc_get_status(bool *detected, uint8_t *version, char *last_uid, size_t last_uid_size)
{
    taskENTER_CRITICAL(&status_lock);
    if (detected) *detected = nfc_detected;
    if (version) *version = nfc_version;
    if (last_uid && last_uid_size > 0) strlcpy(last_uid, nfc_last_uid, last_uid_size);
    taskEXIT_CRITICAL(&status_lock);
}
