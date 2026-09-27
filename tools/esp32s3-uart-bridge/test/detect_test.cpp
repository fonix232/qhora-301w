// Host test for detectBaud(): synthesises 8N1 text the way the RMT would see it
// (10 MHz tick, random phase, jitter, idle gaps) and checks the verdict.
//
//   c++ -std=c++17 -O2 -I src test/detect_test.cpp -o /tmp/detect_test && /tmp/detect_test

#include <random>
#include <stdio.h>
#include <string>
#include <vector>

#include "detect.h"

static const double TICK_HZ = 10e6;
static std::mt19937 rng(1);

// Edge times (seconds) of `text` sent at `baud`, with `skew` clock error,
// `jitter` (fraction of a bit, per edge) and `gapBits` idle after each '\n'.
static std::vector<uint16_t> capture(const std::string &text, double baud, double skew, double jitter, double gapBits,
                                     size_t maxPulses) {
  double bit = 1.0 / (baud * (1 + skew));
  std::vector<std::pair<double, bool>> levels;  // (duration, high)
  auto push = [&](bool high, double d) {
    if (!levels.empty() && levels.back().second == high) {
      levels.back().first += d;
    } else {
      levels.push_back({d, high});
    }
  };
  for (char c : text) {
    push(false, bit);  // start
    for (int i = 0; i < 8; i++) {
      push((c >> i) & 1, bit);
    }
    push(true, bit);  // stop
    if (c == '\n') {
      push(true, gapBits * bit);
    }
  }
  // Quantise edges to the tick clock from a random phase, add jitter, apply
  // the 0.3 us glitch filter's effect (drop anything under 3 ticks).
  std::uniform_real_distribution<double> phase(0, 1), jit(-jitter, jitter);
  double t = phase(rng) / TICK_HZ, last = 0;
  std::vector<uint16_t> out;
  for (auto &[d, high] : levels) {
    double end = t + d + jit(rng) * bit;
    double w = floor(end * TICK_HZ) - floor(t * TICK_HZ);
    t = end;
    (void)last;
    if (w < 3 || w >= 30000) {
      continue;  // filtered, or a capture boundary (idle >= 3 ms)
    }
    out.push_back(pulse((uint32_t)w, high));
    if (out.size() == maxPulses) {
      break;
    }
  }
  return out;
}

static const std::string BOOT =
    "Format: Log Type - Time(microsec) - Message - Optional Info\n"
    "S - QC_IMAGE_VERSION_STRING=BOOT.BF.3.3.1-00158\n"
    "U-Boot 2016.01 (Aug 18 2020 - 10:12:53 +0800)\n"
    "DRAM:  smem ram ptable found: ver: 1 len: 4\n"
    "Hit any key to stop autoboot:  2 \n";

static int failures = 0;

static void expect(const char *what, uint32_t got, uint32_t want) {
  bool ok = got == want;
  failures += !ok;
  printf("%s  %-44s got %7u want %7u\n", ok ? "PASS" : "FAIL", what, got, want);
}

int main() {
  char name[96];
  for (uint32_t b : STANDARD_BAUDS) {
    for (double skew : {-0.02, 0.0, 0.02}) {
      auto p = capture(BOOT, b, skew, 0.05, 20, 160);
      snprintf(name, sizeof(name), "%u baud, clock %+.0f%%", b, skew * 100);
      expect(name, detectBaud(p.data(), p.size(), TICK_HZ), b);
    }
  }
  // Interactive echo: long idle between every character.
  {
    std::string slow;
    for (char c : std::string("root@OpenWrt:~# ls /tmp\n")) {
      slow += c;
      slow += '\n';
    }
    auto p = capture(slow, 115200, 0, 0.05, 150, 160);
    expect("115200, idle after every character", detectBaud(p.data(), p.size(), TICK_HZ), 115200);
  }
  // Too few pulses to decide.
  {
    auto p = capture("OK\n", 115200, 0, 0.05, 20, 160);
    expect("115200, only three characters", detectBaud(p.data(), p.size(), TICK_HZ), 0);
  }
  // Odd rate: nowhere near a standard one, reported as measured.
  {
    auto p = capture(BOOT, 1843200, 0, 0.03, 20, 160);
    uint32_t got = detectBaud(p.data(), p.size(), TICK_HZ);
    bool ok = got > 1843200 * 0.97 && got < 1843200 * 1.03;
    failures += !ok;
    printf("%s  %-44s got %7u want ~1843200\n", ok ? "PASS" : "FAIL", "1843200 (non-standard)", got);
  }
  // Random pulse widths (noise, PWM, a floating line) must not pass.
  {
    std::uniform_int_distribution<int> w(3, 3000);
    int passed = 0;
    for (int trial = 0; trial < 1000; trial++) {
      std::vector<uint16_t> p;
      for (int i = 0; i < 160; i++) {
        p.push_back(pulse(w(rng), i & 1));
      }
      passed += detectBaud(p.data(), p.size(), TICK_HZ) != 0;
    }
    expect("1000 random-noise captures accepted", passed, 0);
  }
  // A square wave is all single-bit pulses of one width: valid UART-shaped
  // (0x55 'U'), and that's fine. A 1 kHz 30% duty PWM is not.
  {
    std::vector<uint16_t> p;
    for (int i = 0; i < 160; i++) {
      p.push_back(pulse(i & 1 ? 7000 : 3000, i & 1));
    }
    expect("1 kHz PWM, 30% duty", detectBaud(p.data(), p.size(), TICK_HZ), 0);
  }
  printf("%s\n", failures ? "FAILED" : "all passed");
  return failures != 0;
}
