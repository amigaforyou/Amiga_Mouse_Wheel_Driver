# A1200Wheel — mouse wheel driver for the A1200HIDToDB9 adapter

An AmigaOS driver that adds support for the **scroll wheel**, **wheel tilt** (horizontal scrolling), **middle button** and **buttons 4/5** of a USB mouse connected to the Amiga through the [A1200HIDToDB9](../) adapter.

Everything goes through **a single mouse port**, over the middle-button line (DB9 pin 5). The joystick port stays free. No hardware changes to the adapter are needed, because pin 5 is already connected.

## Requirements

| | |
|---|---|
| Kickstart / OS | 2.0 (V36) or newer; tested with 3.1 and 3.2.x |
| CPU | any 68000–68060 (PiStorm works too) |
| Adapter firmware | **`A1200HIDToDB9_wheel_v2`** or newer |

> [!IMPORTANT]
> Driver 1.2 works **only** with firmware `wheel_v2`, and vice versa, because the packet format changed. Update both at the same time.

## Files

| File | Purpose |
|---|---|
| `prebuilt/A1200Wheel` | ready-to-use Amiga driver |
| `prebuilt/A1200HIDToDB9_wheel_v2.hex` / `.bin` | adapter firmware (STM32F401) |
| `amiga/A1200Wheel.s` | driver source code (68k assembly) |

## Installation

### 1. Flash the adapter

Write `prebuilt/A1200HIDToDB9_wheel_v2.hex` to the STM32F401 with any tool you like, for example STM32CubeProgrammer and an ST-Link.

### 2. Copy the driver to the Amiga

Transfer `A1200Wheel` to the Amiga (CF/SD card, floppy, network, PiStorm, etc.) and copy it to `C:`:

```
Copy A1200Wheel TO C:
Protect C:A1200Wheel +rwed
```

### 3. Start it automatically at boot

Open `S:User-Startup` in an editor:

```
ED S:User-Startup
```

Add this line at the end:

```
Run >NIL: C:A1200Wheel QUIET
```

Save (in `ED`: <kbd>Esc</kbd>, then `X` and <kbd>Enter</kbd>) and reboot the Amiga.

Alternatively, put `A1200Wheel` in `SYS:WBStartup` together with a tool icon.

### 4. Configure the system

**OS 3.2.x.** Intuition handles the wheel natively. Enable **Scroll Wheel Enabled** in `Prefs/IControl`, and the wheel will scroll the window under the pointer. No extra software is needed.

**OS 3.1 / 3.5 / 3.9.** The system itself does not handle the wheel. For scrolling in ordinary programs, install [FreeWheel](https://aminet.net/package/util/mouse/FreeWheel) or a similar tool. MUI programs and many modern applications understand the wheel on their own.

## Options

```
A1200Wheel [QUIET] [RAWKEYONLY] [SPEED=1..20]
```

| Option | Description |
|---|---|
| `SPEED=n` | scroll speed: steps per wheel notch (1–20, default 1) |
| `QUIET` | print no messages |
| `RAWKEYONLY` | send RAWKEY events only, without `IECLASS_NEWMOUSE`; use it if a program scrolls twice per notch |

Example with faster scrolling:

```
Run >NIL: C:A1200Wheel QUIET SPEED=3
```

Running `A1200Wheel` a second time stops the driver that is already running. You can also stop it with <kbd>Ctrl</kbd>+<kbd>C</kbd> / `Break`.

To check the version: `Version C:A1200Wheel`.

## Events

The driver sends events following the **NewMouse** standard:

| Action | Event |
|---|---|
| wheel up / down | RAWKEY `$7A` / `$7B` (+ `IECLASS_NEWMOUSE`) |
| tilt left / right | RAWKEY `$7C` / `$7D` (+ `IECLASS_NEWMOUSE`) |
| button 4 / button 5 | RAWKEY `$7E` / `$7F` (+ `IECLASS_NEWMOUSE`) |
| middle button | RAWMOUSE `IECODE_MBUTTON` |

While the driver is not running, the adapter behaves as an ordinary three-button mouse: the middle button goes straight to pin 5. The boot menu, games and systems without the driver work as before.

## Error messages

| Message | Meaning |
|---|---|
| `cannot share the middle button pin (unknown potgo.resource)` | `potgo.resource` has been replaced by an unknown version, so the driver does not risk working with it |
| `cannot open potgo.resource` / `input.device` | a system resource is not available |
| `out of memory` | not enough memory |

## Troubleshooting

- **The wheel does nothing.** Check that the adapter has firmware `wheel_v2` and the driver is version 1.2 (`Version C:A1200Wheel`). On OS 3.2, check **Scroll Wheel Enabled** in IControl. On 3.1/3.9, check that FreeWheel is running.
- **Scrolling is too slow.** Add `SPEED=2`…`SPEED=5`.
- **A program scrolls two steps per notch.** Start the driver with `RAWKEYONLY`.

## How it works

Once per frame (50/60 Hz), in the VBlank interrupt, the driver:

1. pulls pin 5 low through `POTGO` for one scan line (64 µs), which is the request;
2. releases the line and waits for the falling edge of the adapter's start bit;
3. receives 15 bits of 64 µs each. Timing comes from the beam position (`VHPOSR`), and the line level is read from `POTINP`.

**Packet (15 bits):**

| Bit | Meaning |
|---|---|
| 0 | start = 0 |
| 1 | sync = 1 |
| 2–6 | wheel counter, 5 bits |
| 7–9 | tilt counter, 3 bits |
| 10 / 11 / 12 | middle button / button 4 / button 5 |
| 13 | parity |
| 14 | stop = 1 |

The counters are absolute. The driver acknowledges each received frame with a short pulse (ACK) in the next request. The adapter advances a counter only after the ACK, and by at most 4 notches per frame. As a result, the scroll direction is never confused, whatever the wheel speed and however many frames are lost. If the ACKs do not get through, the adapter switches to working without them after one second.

Pin 5 is owned by the system `gameport.device`, so the driver does not take it over but shares it with the system: it writes `POTGO` directly and preserves the bits the system holds. The `potgo.resource` code is the same in Kickstart 2.04–3.2.3, and the driver verifies it at startup.

The driver uses about 1.2 ms of CPU time per frame (~6% on a 7 MHz 68000).

## Building from source

You need the [vasm](http://sun.hasenbraten.de/vasm/) assembler (`m68k` CPU, `mot` syntax):

```
vasmm68k_mot -Fhunkexe -kick1hunks -m68000 -nosym -o A1200Wheel A1200Wheel.s
```

## Testing

- The driver has been tested on a real Amiga 1200.
- It was also run in a 68000/68020/68030 emulator (Musashi) with a model of the Amiga timing and a model of the adapter built from the same protocol code as the firmware. The tests covered:
  - PAL, NTSC and 31 kHz modes;
  - bus slowdown by the chipset;
  - interrupt load;
  - a mouse without the adapter;
  - running the driver a second time;
  - starting it from Workbench.

  The test bench is in `tools/amiga-test/`.
