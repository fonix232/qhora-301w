// Baud-rate detection from captured pulse widths. No Arduino dependencies, so
// test/detect_test.cpp can run it on the host.
#pragma once

#include <algorithm>
#include <math.h>
#include <stddef.h>
#include <stdint.h>

static const uint32_t STANDARD_BAUDS[] = {9600,   19200,  38400,  57600,  74880,   115200,  230400,
                                          250000, 460800, 500000, 921600, 1000000, 1500000};
static const size_t DETECT_MAX_PULSES = 512;
static const size_t DETECT_MIN_PULSES = 60;  // in-frame pulses needed for a verdict

// Each pulse is a width in ticks with the line level in bit 15.
static inline uint16_t pulse(uint32_t ticks, bool high) {
  return (uint16_t)(ticks | (high ? 0x8000 : 0));
}

// If the pulses look like 8N1 UART, return the baud rate; else 0.
// Every pulse is a whole number of bit times: low runs 1-9 bits (start bit plus
// up to eight 0s), high runs 1-9 bits, or longer when the line idles between
// characters. Text has plenty of single-bit runs, so a low percentile of the
// widths is one bit; the exact bit time then comes from all in-frame pulses.
static uint32_t detectBaud(const uint16_t *pulses, size_t count, uint32_t tickHz) {
  if (count == 0 || count > DETECT_MAX_PULSES) {
    return 0;
  }
  uint16_t sorted[DETECT_MAX_PULSES];
  for (size_t i = 0; i < count; i++) {
    sorted[i] = pulses[i] & 0x7fff;
  }
  std::sort(sorted, sorted + count);
  float low = sorted[count / 20];  // 5th percentile
  float sum = 0;
  size_t n = 0;
  for (size_t i = 0; i < count; i++) {
    if (sorted[i] >= 0.7f * low && sorted[i] <= 1.4f * low) {
      sum += sorted[i];
      n++;
    }
  }
  if (!n) {
    return 0;
  }
  float bit = sum / n;
  size_t counted = 0, good = 0;
  float widths = 0, bits = 0;
  for (size_t i = 0; i < count; i++) {
    float w = pulses[i] & 0x7fff;
    bool high = pulses[i] >> 15;
    float k = roundf(w / bit);
    if (high && k > 9) {
      continue;  // idle between characters
    }
    counted++;
    if (k >= 1 && k <= 9 && fabsf(w - k * bit) <= 0.25f * bit) {
      good++;
      widths += w;
      bits += k;
    }
  }
  if (counted < DETECT_MIN_PULSES || good * 10 < counted * 9) {
    return 0;
  }
  float measured = tickHz * bits / widths;
  uint32_t best = STANDARD_BAUDS[0];
  for (uint32_t b : STANDARD_BAUDS) {
    if (fabsf(measured - b) < fabsf(measured - best)) {
      best = b;
    }
  }
  if (fabsf(measured - best) / best <= 0.05f) {
    return best;
  }
  return (uint32_t)(measured / 100 + 0.5f) * 100;  // odd rate: trust the measurement
}
