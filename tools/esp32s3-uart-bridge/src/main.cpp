// USB <-> UART bridge for the Waveshare ESP32-S3-Zero that works out the wiring
// by itself: it listens on two GPIOs without driving either, finds the one
// carrying the target's TX and its baud rate, then bridges it to USB with RX on
// that pin and TX on the other. See README.md.

#include <Arduino.h>
#include <Preferences.h>
#include <atomic>
#include <driver/gpio.h>
#include <stdarg.h>

#include "detect.h"

#ifndef PIN_A
#define PIN_A 7
#endif
#ifndef PIN_B
#define PIN_B 8
#endif
#ifndef LED_PIN
#define LED_PIN 21  // WS2812 on the S3-Zero
#endif
#ifndef LED_ORDER
#define LED_ORDER LED_COLOR_ORDER_RGB  // the S3-Zero's LED is RGB, not GRB
#endif
#ifndef BOOT_PIN
#define BOOT_PIN 0
#endif

static const uint32_t RMT_HZ = 10000000;  // capture resolution: 0.1 us
static const uint16_t IDLE_TICKS = 30000;  // 3 ms without an edge ends a capture
static const size_t SYMBOLS = 96;          // RMT_MEM_NUM_BLOCKS_2
static const size_t MIN_PULSES = 160;      // pulses to gather before deciding

enum State { LISTENING, BRIDGING };

struct Probe {
  int pin;
  rmt_data_t sym[SYMBOLS];
  size_t n;
  uint16_t pulses[DETECT_MAX_PULSES];
  size_t count;
};

static State state;
static Probe probes[2] = {{PIN_A}, {PIN_B}};
static int rxPin = -1, txPin = -1;
static uint32_t baud = 0;
static Preferences prefs;
static std::atomic<uint32_t> frameErrors{0};
static bool hostWasConnected = false, hintShown = false;

static void led(uint8_t r, uint8_t g, uint8_t b) {
  rgbLedWriteOrdered(LED_PIN, LED_ORDER, r, g, b);
}

// Status lines go to the USB terminal, on a line of their own.
static void note(const char *fmt, ...) {
  if (!Serial) {
    return;
  }
  char buf[192];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  Serial.printf("\r\n[uart-bridge] %s\r\n", buf);
}

static void banner() {
  if (state == BRIDGING) {
    note("RX=GPIO%d TX=GPIO%d %lu 8N1. BOOT button: forget and re-detect.", rxPin, txPin, (unsigned long)baud);
  } else {
    note("listening on GPIO%d and GPIO%d, nothing driven. Make the target print something (power it on or reset it).",
         PIN_A, PIN_B);
  }
}

static bool armProbe(Probe &p) {
  p.n = SYMBOLS;
  return rmtReadAsync(p.pin, p.sym, &p.n);
}

static void startListening() {
  Serial1.end();
  for (auto &p : probes) {
    pinMode(p.pin, INPUT);  // release the old TX line before anything else
    rmtInit(p.pin, RMT_RX_MODE, RMT_MEM_NUM_BLOCKS_2, RMT_HZ);
    rmtSetRxMaxThreshold(p.pin, IDLE_TICKS);
    rmtSetRxMinThreshold(p.pin, 3);  // ignore glitches under 0.3 us
    gpio_pullup_en((gpio_num_t)p.pin);  // an unconnected or input line idles high
    p.count = 0;
    armProbe(p);
  }
  state = LISTENING;
  hintShown = false;
  led(0, 0, 16);
  banner();
}

static void startBridge(int rx, uint32_t rate) {
  for (auto &p : probes) {
    rmtDeinit(p.pin);
  }
  rxPin = rx;
  txPin = (rx == PIN_A) ? PIN_B : PIN_A;
  baud = rate;
  frameErrors = 0;
  Serial1.setRxBufferSize(8192);
  Serial1.begin(baud, SERIAL_8N1, rxPin, txPin);
  Serial1.onReceiveError([](hardwareSerial_error_t e) {
    if (e == UART_FRAME_ERROR) {
      frameErrors++;
    }
  });
  prefs.putInt("rx", rxPin);
  prefs.putUInt("baud", baud);
  state = BRIDGING;
  led(0, 16, 0);
  banner();
}

// Take the pulse widths out of a finished capture.
static void collect(Probe &p) {
  for (size_t i = 0; i < p.n; i++) {
    uint32_t w[2] = {p.sym[i].duration0, p.sym[i].duration1};
    uint32_t lvl[2] = {p.sym[i].level0, p.sym[i].level1};
    for (int j = 0; j < 2; j++) {
      if (w[j] == 0) {
        return;  // end marker
      }
      if (w[j] < IDLE_TICKS && p.count < DETECT_MAX_PULSES) {
        p.pulses[p.count++] = pulse(w[j], lvl[j]);
      }
    }
  }
}

static void listen() {
  for (auto &p : probes) {
    if (!rmtReceiveCompleted(p.pin)) {
      continue;
    }
    collect(p);
    if (p.count >= MIN_PULSES) {
      uint32_t rate = detectBaud(p.pulses, p.count, RMT_HZ);
      if (rate) {
        startBridge(p.pin, rate);
        return;
      }
      p.count = 0;  // noise, or not enough single bits yet: take a fresh sample
    }
    armProbe(p);
  }
  // Typing before the target has said anything can't go anywhere yet.
  if (Serial.available()) {
    while (Serial.available()) {
      Serial.read();
    }
    if (!hintShown) {
      note("not bridging yet: the target hasn't sent anything to detect. Reset or power it on.");
      hintShown = true;
    }
  }
}

static void bridge() {
  uint8_t buf[256];
  size_t n = Serial.available();
  if (n) {
    n = Serial.read(buf, min(n, sizeof(buf)));
    Serial1.write(buf, n);
  }
  n = Serial1.available();
  if (n) {
    n = Serial1.read(buf, min(n, sizeof(buf)));
    Serial.write(buf, n);
  }
  // A stream of framing errors means the rate or the line changed.
  static uint32_t windowStart = 0;
  if (millis() - windowStart > 2000) {
    if (frameErrors >= 20) {
      note("many framing errors at %lu baud, detecting again", (unsigned long)baud);
      prefs.clear();
      startListening();
    }
    frameErrors = 0;
    windowStart = millis();
  }
}

static void checkButton() {
  static bool wasDown = false;
  static uint32_t downSince = 0;
  bool down = digitalRead(BOOT_PIN) == LOW;
  if (down && !wasDown) {
    downSince = millis();
  }
  if (!down && wasDown && millis() - downSince > 50) {
    note("BOOT pressed: forgetting the wiring and detecting again");
    prefs.clear();
    startListening();
  }
  wasDown = down;
}

void setup() {
  Serial.setTxBufferSize(4096);
  Serial.setTxTimeoutMs(0);  // never block when no terminal is open
  Serial.begin();
  pinMode(BOOT_PIN, INPUT_PULLUP);
  prefs.begin("uartbridge", false);
  int rx = prefs.getInt("rx", -1);
  uint32_t rate = prefs.getUInt("baud", 0);
  if ((rx == PIN_A || rx == PIN_B) && rate) {
    startBridge(rx, rate);  // remembered from last time
  } else {
    startListening();
  }
}

void loop() {
  bool connected = Serial;
  if (connected && !hostWasConnected) {
    banner();
  }
  hostWasConnected = connected;
  checkButton();
  if (state == LISTENING) {
    listen();
  } else {
    bridge();
  }
}
