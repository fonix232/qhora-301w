# ESP32-S3-Zero UART bridge

Firmware that turns a Waveshare ESP32-S3-Zero into a USB serial adapter which works out the wiring by itself. It listens on GPIO7 and GPIO8 without driving either, finds the one carrying the target's TX and its baud rate, then bridges it to the S3's built-in USB serial port: RX on that pin, TX on the other. No driver is needed on macOS or Linux.

## Wiring

Target GND to a GND pin, and the target's TX and RX to GPIO7 and GPIO8 in either order. Never connect the target's VCC pin. The S3 is 3.3 V logic, which matches the QHora-301W console (115200 8N1, 3.3 V). Don't use it on 1.8 V or 5 V consoles without a level shifter.

## Flash

```sh
cd tools/esp32s3-uart-bridge
pio run -t upload
```

If the board doesn't show up as a USB device, hold BOOT while plugging it in (or hold BOOT and tap RESET). That starts the ROM loader, which always enumerates as `303a:1001` (USB JTAG/serial debug unit). Flash from there, then tap RESET. A charge-only USB-C cable also shows up as nothing at all.

`platformio.ini` pins upload and monitor to `hwgrep://VID:PID=303A:`, so they only ever open an Espressif USB device and fail with "no ports found" otherwise. Without that, PlatformIO falls back to whatever serial port exists when the board isn't found, which can be an unrelated device's firmware-update port.

## Use

```sh
pio device monitor              # from this directory: raw passthrough, Enter sends CR, logs to logs/
screen /dev/cu.usbmodemXXXX 115200  # or any terminal; the USB-side baud rate is ignored
```

For other terminals, `pio device list` shows which port is the S3 (`VID:PID=303A:1001`). Don't guess with a `usbmodem*` glob, since other devices use that name too.

1. Power on or reset the target so it prints something. Detection needs a line or two of output (160 pulses).
2. The bridge prints `[uart-bridge] RX=GPIO7 TX=GPIO8 115200 8N1` (or whatever it found) and starts passing data both ways. It only prints `[uart-bridge]` lines when its state changes. While it is still listening, pressing any key prints the status (nothing is sent anywhere yet).
3. The wiring and rate are remembered across power cycles, so a target that is already up and silent can be typed at straight away.

LED: blue while listening (both pins released), green while bridging (TX driven). If green shows as red, build with `-DLED_ORDER=LED_COLOR_ORDER_GRB`.

Press BOOT at any time to forget the wiring and listen again. Do this whenever you move the wires: with a remembered mapping the bridge drives the TX pin, and if that pin now goes to the target's TX the two outputs fight. A burst of framing errors (20 in 2 s) also makes it listen again, which covers a target that changes baud rate.

## How detection works

Both pins are captured with the RMT peripheral at 0.1 µs resolution, with pull-ups on and a 0.3 µs glitch filter. A capture ends after 3 ms of idle. Every pulse in an 8N1 signal is a whole number of bit times: low runs are 1–9 bits, high runs 1–9 bits or longer when the line idles between characters. The 5th percentile of the widths gives a rough bit time, since text has plenty of single-bit runs. The verdict needs at least 60 in-frame pulses, and 90% of them must be within 25% of a whole number of bits. The exact bit time then comes from the sum of widths over the sum of bits. The result snaps to a standard rate (9600 to 1500000) if one is within 5%, otherwise the measured rate is used. The target's RX line never toggles, so it never passes.

`src/detect.h` holds the analysis and has no Arduino dependencies. `test/detect_test.cpp` runs it on the host against synthesised 8N1 text: every standard rate at ±2% clock error, with idle gaps, too little data, a non-standard rate, random noise and PWM:

```sh
c++ -std=c++17 -O2 -I src test/detect_test.cpp -o /tmp/detect_test && /tmp/detect_test
```

Limits: 8N1 only (other framings will mostly throw framing errors and re-detect). Above about 1.5 Mbaud a bit is only a few RMT ticks, so rates there are rough. Line inversion (idle low) isn't handled.
