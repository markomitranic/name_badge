# Linux Kernel & Device Tree — Trellis Badge

AI-consumable reference for the Linux kernel build and device tree used by the Protolux Trellis e-ink name badge. Captures enough detail to reconstitute context after the upstream `nerves_system_trellis` clone is removed.

Sibling docs:
- [bootloader_uboot.md](./bootloader_uboot.md)
- [nerves_system_trellis.md](./nerves_system_trellis.md)
- [usb_fel_loaders.md](./usb_fel_loaders.md)
- [elixir_application.md](./elixir_application.md)

---

## 1. Table of Contents

1. [Table of Contents](#1-table-of-contents)
2. [What the Linux kernel is](#2-what-the-linux-kernel-is)
3. [The specific kernel (6.12.32)](#3-the-specific-kernel-61232)
4. [Kernel defconfig highlights](#4-kernel-defconfig-highlights)
5. [Linux patches applied](#5-linux-patches-applied)
6. [What is a device tree](#6-what-is-a-device-tree)
7. [The Trellis device tree](#7-the-trellis-device-tree)
8. [GPIO line names](#8-gpio-line-names)
9. [Peripheral assignments](#9-peripheral-assignments)
10. [E-ink display interface](#10-e-ink-display-interface)
11. [User-space hardware access](#11-user-space-hardware-access)
12. [How the kernel + DTS get into firmware](#12-how-the-kernel--dts-get-into-firmware)
13. [When you'd modify this](#13-when-youd-modify-this)
14. [Recovery scenarios](#14-recovery-scenarios)

---

## 2. What the Linux kernel is

The Linux kernel is the OS core running on the badge's SoC. It owns CPU scheduling, memory management, drivers for every on-chip and off-chip peripheral (SPI, MMC, USB, GPIO, WiFi, RTC, crypto engine), and it exposes hardware to user-space through `/dev/*`, `/sys/*`, and `/proc/*`. On the Trellis badge, the kernel runs alongside a Buildroot-produced root filesystem; the Erlang VM is just one of the user-space processes it hosts.

Key concepts relevant here:
- **Kernel config (defconfig)**: a flat `CONFIG_*=y|m|n` file fed to `make` that selects which subsystems and drivers are compiled.
- **Device tree (DT/DTS/DTB)**: a data structure describing hardware topology (where peripherals live, which pins they use, their clocks/regulators). Loaded by U-Boot at boot and parsed by drivers at init.
- **Modules (`=m`)**: drivers compiled as loadable `.ko` files instead of built into the zImage; loaded on demand via `modprobe`/udev.

## 3. The specific kernel (6.12.32)

- **Version:** Linux 6.12.32 (LTS-adjacent stable, pulled by Buildroot as source tarball).
- **Defconfig:** `/nerves_system_trellis/linux/linux_defconfig` — 224 lines, custom derivative of `sunxi_defconfig`.
- **Patch directory:** `/nerves_system_trellis/linux/` (4 `.patch` files applied in order during Buildroot's kernel prepare step).
- **Built by:** Buildroot under `nerves_system_trellis`. Buildroot downloads the upstream 6.12.32 tarball, applies the 4 patches, compiles with the defconfig, compiles each enabled DTS, and bundles the result.
- **Kernel command line** (baked in via `CONFIG_CMDLINE`):
  ```
  console=ttyS4,115200
  ```
  U-Boot augments this at boot with rootfs and `nerves_fw_*` args from its environment. The `ttyS4` endpoint corresponds to UART4 → the SoC's debug pins PD7/PD8.
- **Output artifacts:**
  - `zImage` — compressed ARM kernel image.
  - `sun8i-t113s-trellis.dtb` — compiled device tree blob.
  - Loadable `.ko` modules (WiFi drivers, spidev, bluetooth, wireguard, etc.).

## 4. Kernel defconfig highlights

Grouped by subsystem. Only load-bearing options shown; the full 224-line file lives at `/nerves_system_trellis/linux/linux_defconfig`.

### Architecture / CPU

```
CONFIG_ARCH_SUNXI=y
CONFIG_SMP=y
CONFIG_NR_CPUS=2
CONFIG_HIGHMEM=y
CONFIG_VFP=y           # Vector Floating Point
CONFIG_NEON=y          # NEON SIMD
CONFIG_CPU_FREQ=y
CONFIG_CPUFREQ_DT=y    # DT-based frequency scaling
CONFIG_PREEMPT=y
CONFIG_NO_HZ_IDLE=y
CONFIG_HIGH_RES_TIMERS=y
```

Rationale: dual Cortex-A7 at 1.2 GHz, ARMv7 hard-float, `HIGHMEM` covers the 256 MB DDR3 window above lowmem, `CPUFREQ_DT` pulls OPP tables from the device tree.

### Filesystems

```
CONFIG_EXT4_FS=y              # application partition
CONFIG_SQUASHFS=y             # rootfs
CONFIG_SQUASHFS_FILE_DIRECT=y
CONFIG_TMPFS=y
# no network filesystems, no DNOTIFY
```

The Nerves A/B rootfs layout uses squashfs (read-only) for `/`. A small ext4 "application data partition" is mounted at `/root` for persistent writable storage.

### Storage / MMC

```
CONFIG_MMC=y
CONFIG_MMC_SUNXI=y
CONFIG_MTD=y
CONFIG_MTD_SPI_NAND=y
CONFIG_MTD_SPI_NOR=y
CONFIG_CMA=y              # Contiguous Memory Allocator
```

Soldered eMMC lands on `/dev/mmcblk0`. MTD/SPI-NAND/SPI-NOR are compiled in but not currently used by this board.

### SPI

```
CONFIG_SPI=y
CONFIG_SPI_SUN4I=y        # SPI0 (unused, disabled in DT)
CONFIG_SPI_SUN6I=y        # SPI1 (e-ink panel)
CONFIG_SPI_SPIDEV=m       # user-space /dev/spidevN.N (module)
```

`SPI_SPIDEV` is a module — loaded on demand by udev/modprobe when the DT binds a spidev child node. The Elixir firmware depends on this.

### GPIO / Input

```
CONFIG_GPIO_SYSFS=y
CONFIG_KEYBOARD_GPIO=y
CONFIG_INPUT_EVDEV=y
```

Buttons are declared in the DTS as `gpio-keys` and surface as `/dev/input/event*`. Additionally, `libgpiod` can open GPIO chips directly (`/dev/gpiochip*`) — this is what `circuits_gpio` uses.

### Serial

```
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_NR_UARTS=8
CONFIG_SERIAL_8250_RUNTIME_UARTS=8
CONFIG_SERIAL_8250_DW=y   # DesignWare UART IP
```

The Allwinner UARTs are DesignWare 8250 variants. UART4 is the console; the others exist but are unused on this board.

### Networking

```
CONFIG_NET=y
CONFIG_INET=y (IPv4)
CONFIG_IPV6=y
CONFIG_IP_MULTIPLE_TABLES=y  # policy routing (VintageNet)
# CONFIG_ETHERNET is not set  (no on-chip Ethernet; USB gadget eth or WiFi only)
```

Policy routing is required by `VintageNet` to prioritise interfaces. No on-chip MAC — uplink is either WiFi (`wlan0`) or USB-gadget Ethernet (`usb0`, host-side).

### Wireless (WiFi) — drivers as modules

```
CONFIG_CFG80211=y
CONFIG_MAC80211=m
CONFIG_RFKILL=y
CONFIG_RFKILL_GPIO=y
CONFIG_RTL8XXXU=m             # RTL8188/8192/8723 USB WiFi
CONFIG_RTL8XXXU_UNTESTED=y
CONFIG_RTW88=m                # newer Realtek driver framework
CONFIG_RTW88_8723DU=m         # RTL8723DU specifically
CONFIG_WIREGUARD=m            # Wireguard VPN (module)
```

The badge uses a Realtek RTL8188FU USB-attached WiFi (visible in dmesg at boot). `rtl8xxxu` is the relevant driver; `rtw88` entries cover newer Realtek silicon that may appear in future revisions. **2.4 GHz only.**

### Bluetooth (modules, off by default)

```
CONFIG_BT=m
CONFIG_BT_HCIUART=m
CONFIG_BT_HCIUART_RTL=y
```

Compiled in case a Realtek combo chip with BT over UART is fitted later.

### Power / RTC / Watchdog

```
CONFIG_POWER_SUPPLY=y
CONFIG_CHARGER_AXP20X=y
CONFIG_BATTERY_AXP20X=y
CONFIG_THERMAL=y
CONFIG_CPU_THERMAL=y
CONFIG_SUN8I_THERMAL=y
CONFIG_WATCHDOG=y
CONFIG_SUNXI_WATCHDOG=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_AC100=y
CONFIG_RTC_DRV_SUNXI=y
```

AXP20X PMIC battery/charger bindings are compiled in (actual battery attachment depends on hardware revision). `SUN8I_THERMAL` + `CPU_THERMAL` allow the CPU to throttle on overheat. The watchdog is exercised at runtime to reboot on kernel hangs.

### USB

```
CONFIG_USB=y
CONFIG_USB_OTG=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_MUSB_HDRC=y        # Mentor Graphics USB
CONFIG_USB_MUSB_GADGET=y
CONFIG_USB_MUSB_SUNXI=y
CONFIG_USB_GADGET=y
CONFIG_USB_ETH=y              # Ethernet-over-USB gadget (usb0 interface)
```

MUSB is the OTG controller used in peripheral/gadget mode (FEL + USB Ethernet). EHCI/OHCI cover host-mode on any second USB port.

### LEDs

```
CONFIG_NEW_LEDS=y
CONFIG_LEDS_CLASS=y
CONFIG_LEDS_GPIO=y
CONFIG_LEDS_PWM=y
CONFIG_LEDS_USER=y
CONFIG_LEDS_SUN50I_A100=y
CONFIG_LEDS_TRIGGER_HEARTBEAT=y
# plus timer, oneshot, activity, gpio, default-on, transient, pattern triggers
```

LED triggers let the kernel drive LEDs without user-space involvement — the status LED defaults to `heartbeat` so you know the kernel is alive even before Erlang boots.

### IIO (ADC — battery voltage reading)

```
CONFIG_IIO=y
CONFIG_AXP20X_ADC=y
CONFIG_SUN20I_GPADC=y         # general-purpose ADC
```

`SUN20I_GPADC` exposes the on-chip general-purpose ADC as `/sys/bus/iio/devices/iio:device0/`. The battery divider is wired to ADC channel 0.

### Crypto (hardware accel)

```
CONFIG_CRYPTO_DEV_SUN4I_SS=y
CONFIG_CRYPTO_DEV_SUN4I_SS_PRNG=y
CONFIG_CRYPTO_DEV_SUN8I_CE=y
CONFIG_CRYPTO_DEV_SUN8I_SS=y
```

Hardware crypto offload for AES/SHA and TRNG. The kernel picks these up via the crypto framework — TLS and `:crypto` benefit transparently.

### CAN bus (included, unused by badge)

```
CONFIG_CAN=y
CONFIG_CAN_SUN4I=y
CONFIG_CAN_J1939=y
CONFIG_CAN_ISOTP=y
```

Compiled in but no CAN transceiver on the board; harmless dead weight.

### NVMEM (serial-number fuses)

```
CONFIG_NVMEM_SUNXI_SID=y   # read SoC SID fuses via /sys/bus/nvmem/...
```

Exposes SoC eFuses as a read-only nvmem device — used by `boardid` to derive the `wisteria-XXXX` hostname.

### Debugging

```
CONFIG_DEBUG_FS=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y   # crash console persistence
CONFIG_PRINTK_TIME=y
CONFIG_PANIC_TIMEOUT=10    # reboot 10s after panic
```

`pstore-ram` saves kernel log to a reserved RAM region across soft reboots — useful for post-mortem after a panic.

## 5. Linux patches applied

Patches live in `/nerves_system_trellis/linux/` and are applied by Buildroot in numeric order before `make zImage`.

| # | Filename | Purpose |
|---|---|---|
| 1 | `0001_dt_bindings_pwm_add_binding_for_allwinner_d1_t113_s3_r329_pwm_controller.patch` | Adds DT binding doc (`Documentation/devicetree/bindings/pwm/allwinner,sun20i-d1-pwm.yaml`) for the D1/T113-S3/R329 PWM controller. Mainline-sourced. |
| 2 | `0002_pwm_add_allwinner_s_d1_t113_s3_r329_socs_pwm_support.patch` | Adds the `pwm-sun20i-d1` kernel driver — 8-channel PWM on D1/T113-S3. |
| 3 | `0003_riscv_dts_allwinner_d1_add_pwm_node.patch` | Adds PWM DT node to the Allwinner D1 RISC-V DTS. Not used on T113 but part of the upstream patch series. |
| 4 | `0004_fix_devm_reset_control_deasserted_error.patch` | Fixes error handling in `devm_reset_control_deasserted()`. |

Collectively: **PWM backports.** Not yet in mainline for this SoC at the pinned 6.12.32 kernel version. The driver compiles but the DT node is disabled on Trellis — if you want PWM on the board, enable the `&pwm` node in the DTS (see §9).

## 6. What is a device tree

A **device tree** (DT) is a tree-structured data file that describes hardware to the kernel: which controllers exist at which addresses, which pins they use, how they are clocked, which regulators power them, and human-readable metadata.

- **`.dts` (source)** — human-authored tree description.
- **`.dtsi` (include)** — shared fragments, typically SoC-wide (`sun8i-t113s.dtsi`).
- **`.dtb` (blob)** — compiled binary loaded by U-Boot and handed to the kernel in register `r2` at entry.
- **`/sys/firmware/devicetree/base/`** — the live tree exposed by the kernel; `cat`-able from user-space for introspection.

Why it matters: the same kernel binary can boot dozens of ARM boards because the board-specific hardware topology lives in the DTB, not the kernel. Change the DTB → change what peripherals the kernel sees, no recompile required.

## 7. The Trellis device tree

- **File:** `/nerves_system_trellis/dts/allwinner/sun8i-t113s-trellis.dts` (223 lines).
- **Includes:** `sun8i-t113s.dtsi` (SoC-level) + GPIO / regulator / LED header definitions.
- **Compatible strings** (from most to least specific):
  ```
  "protolux,trellis-t113"
  "allwinner,sun8i-t113s"
  "allwinner,sun8i"
  ```
  The kernel walks this list looking for a matching machine description; generic `sun8i` support covers the common sunxi bring-up paths.
- **Model:** `Trellis T113-S4`.
- **Debug console hint:** `stdout-path = "serial4:115200n8"` — tells early console code to use UART4 at 115200 8N1.
- **Separate U-Boot DT:** `/nerves_system_trellis/uboot/sun8i-t113s-trellis.dts` — used only by U-Boot itself. U-Boot and the kernel have distinct DTs because U-Boot needs extra properties (DRAM init, bootcmd hints) that don't belong in the kernel DT. See [bootloader_uboot.md](./bootloader_uboot.md).

## 8. GPIO line names

The DTS assigns `gpio-line-names = <...>` on each sunxi GPIO port (PB, PD, PE). These strings are what `libgpiod` and `circuits_gpio` resolve when opening a GPIO by name. Changing a name here silently breaks the Elixir app — it opens pins **by name**, not by port/pin number.

Key named lines (only the ones the firmware touches):

| Port/Pin | Name | Purpose |
|---|---|---|
| PB2 | `WIFI_EN` | Enables WiFi chip (driven by `NameBadge.Wifi` power manager) |
| PD4 | `BTN_1` | Button 1 (upper) |
| PD5 | `BTN_2` | Button 2 (lower, long-press = back) |
| PD16 | `EPD_DC` | E-ink Data/Command line |
| PD17 | `EPD_RESET` | E-ink panel reset (active-low) |
| PD18 | `EPD_BUSY` | E-ink busy input (panel signals ready) |
| PE9 | `LED_1` | Status LED (red), default trigger: heartbeat |
| PE10 | `LED_2` | Activity LED |

Named lines are what `Circuits.GPIO.open("EPD_DC", :output)` opens — libgpiod resolves the string to chip/line numbers by walking the `gpio-line-names` property.

To inspect at runtime:
```sh
gpioinfo                    # lists all chips with line names + current state
cat /sys/kernel/debug/pinctrl/*/pinmux-pins
```

## 9. Peripheral assignments

### UART4 (debug console)

```dts
uart4_pd_pins: pins "PD7", "PD8", function "uart4";
&uart4 { status = "okay"; };
```

Routes UART4 TX/RX to PD7/PD8. Combined with `CONFIG_CMDLINE=console=ttyS4,115200` and `stdout-path`, this gives you the boot/debug console. Accessible via test pads on the board; requires a 3.3 V UART adapter.

### SPI1 (e-ink panel)

```dts
spi1_pd_pins: pins "PD10", "PD11", "PD12", "PD13", function "spi1";
&spi1 {
    status = "okay";
    spidev0: spidev@0 {
        compatible = "menlo,m53cpld";   /* dummy compatible so spidev binds */
        reg = <0>;
        spi-max-frequency = <10000000>; /* 10 MHz */
    };
};
```

- `PD10..PD13` → SPI1 SCK/MOSI/MISO/CS (exact order per SoC docs).
- `spidev@0` uses a "dummy" compatible string (`menlo,m53cpld`) purely because the mainline kernel refuses to bind `spidev` to arbitrary compatibles — `menlo,m53cpld` is on the spidev whitelist.
- Result: `/dev/spidev0.0` appears at boot. The Elixir `eink` driver opens it via `Circuits.SPI`.
- 10 MHz is a conservative clock; the panel tolerates higher but this gives margin on the flex cable.

### MMC0 (eMMC storage)

```dts
&mmc0 {
    vmmc-supply = <&reg_3v3>;
    disable-wp;
    bus-width = <4>;
    max-frequency = <50000000>;     /* 50 MHz */
    non-removable;                   /* soldered eMMC */
    broken-cd;                       /* no card-detect pin */
    no-1-8-v;
    status = "okay";
};
```

Gives `/dev/mmcblk0` at boot. `non-removable` + `broken-cd` tell the kernel not to wait for card-detect; `no-1-8-v` forbids the UHS voltage switch sequence.

### USB OTG (FEL + USB-gadget Ethernet)

```dts
&usb_otg { dr_mode = "peripheral"; };   /* device/gadget mode */
&usbphy { status = "okay"; };
&ehci1  { status = "okay"; };            /* USB 2.0 host on a second port */
&ohci1  { status = "okay"; };            /* USB 1.1 host */
```

`peripheral` mode on the main USB-C port means the badge is always a USB device — this is how `mix burn` (FEL) and USB-Ethernet-gadget (for SSH over USB) both work. EHCI/OHCI exist for any secondary host port present on the board.

### RTC, watchdog, crypto, GPADC

All four are explicitly `status = "okay"` in the DTS, enabling the drivers that were compiled in via defconfig.

### Regulators (fixed)

| Regulator | Voltage | Notes |
|---|---|---|
| `reg_vcc5v` | 5.0 V | Always-on; input from USB |
| `reg_3v3` | 3.3 V | Derived from 5 V, always-on; supplies `vcc-pb/c/d/e/f/g` (all GPIO banks) |
| `reg_vcc_core` | 0.88 V | Supplies both CPU0 and CPU1 |

No dynamic voltage scaling — `CONFIG_CPUFREQ_DT` switches frequency only, not voltage, because the regulators are fixed.

### Clock

```dts
&dcxo { clock-frequency = <24000000>; };   /* 24 MHz xtal */
```

### Disabled peripherals

Explicitly set `status = "disabled"` in the DTS:
- `&spi0` — second SPI controller, unused.
- `&mixer0`, `&tcon_top`, `&tcon_lcd0` — display controller blocks; the badge uses SPI-attached e-ink, not a parallel RGB panel.
- `&pwm` — PWM DT node disabled by default. Driver is compiled (from the 4 patches above); flip `status = "okay"` to use.

### LEDs (GPIO-driven)

```dts
led-1 {
    color = <LED_COLOR_ID_RED>;
    function = LED_FUNCTION_STATUS;
    gpios = <&pio 4 9 GPIO_ACTIVE_HIGH>;    /* PE9 */
    linux,default-trigger = "heartbeat";     /* kernel-space heartbeat blink */
};
```

`&pio 4 9` = port 4 (PE, 0-indexed B=1, C=2, D=3, E=4), pin 9. `heartbeat` trigger blinks with a characteristic pulse resembling a double heartbeat — visual indicator the kernel is alive.

## 10. E-ink display interface

The 400×300 1-bit panel connects via a 4-wire SPI + 3-wire control interface.

| Signal | Pin | Direction | Notes |
|---|---|---|---|
| SPI SCK  | PD10 | out | SPI1 clock |
| SPI MOSI | PD11 | out | SPI1 data to panel |
| SPI MISO | PD12 | in  | SPI1 data from panel (rarely used) |
| SPI CS   | PD13 | out | SPI1 chip-select |
| `EPD_DC`    | PD16 | out | High = data, low = command (per SSD16xx protocol) |
| `EPD_RESET` | PD17 | out | Active-low panel reset, pulsed on init |
| `EPD_BUSY`  | PD18 | in  | Panel drives high while refresh in progress |

User-space flow:
1. `Circuits.SPI.open("spidev0.0", speed_hz: 10_000_000)` — opens `/dev/spidev0.0`.
2. `Circuits.GPIO.open("EPD_DC" | "EPD_RESET" | "EPD_BUSY", ...)` — libgpiod lookup by name.
3. Driver pulses `EPD_RESET` low → high, then sends command/data bytes over SPI while toggling `EPD_DC`.
4. After issuing a refresh command the driver polls `EPD_BUSY` (or uses `Circuits.GPIO.set_interrupts/2`) until the panel finishes.

Bottleneck: the panel itself, not SPI — full refreshes take ~1.5 s regardless of bus speed.

## 11. User-space hardware access

Summary of how the Elixir firmware touches hardware without any kernel changes:

| What | Path / API | Elixir wrapper |
|---|---|---|
| GPIO by name | `/dev/gpiochip*` via libgpiod (resolves `gpio-line-names`) | `Circuits.GPIO.open("EPD_DC", :output)` |
| SPI | `/dev/spidev0.0` (spidev char device) | `Circuits.SPI.open("spidev0.0")` |
| ADC (battery V) | `/sys/bus/iio/devices/iio:device0/in_voltage0_raw` — 12-bit, 0–4095 | `NameBadge.Battery`; formula: `raw / 4095 * 1.8 * 9.8823529412` V (divider 453k + 51k) |
| Serial ID (SID fuses) | `/sys/bus/nvmem/devices/sunxi-sid0/nvmem` — 16 bytes | `/etc/boardid.config` → `wisteria-XXXX` hostname |
| U-Boot env | `fw_printenv` / `fw_setenv` per `/etc/fw_env.config` (→ `/dev/mmcblk0` @ offset `0x400000`, 128 KB) | Nerves runtime + `Nerves.Runtime.KV` |
| Kernel log | `dmesg` / `/dev/kmsg` | `:logger` optional handler |
| WiFi | `wpa_supplicant` + `cfg80211` netlink | `VintageNet` / `VintageNetWiFi` |
| LEDs | `/sys/class/leds/<name>/{brightness,trigger}` | Direct file I/O |
| Buttons | `/dev/input/event*` via `gpio-keys` | `input_event` port or `evdev` lib |

Rule of thumb: **if a subsystem exposes a char device or a sysfs node, user-space can reach it without kernel edits.** The kernel edits only come into play when a peripheral lacks a generic class driver.

## 12. How the kernel + DTS get into firmware

1. `mix firmware` in `name_badge` pulls the `nerves_system_trellis` artifact (Hex pkg), which is a prebuilt Buildroot output: kernel, DT, U-Boot, rootfs skeleton.
2. Buildroot, when building `nerves_system_trellis` itself, runs:
   - Downloads the 6.12.32 source tarball.
   - Applies the 4 `.patch` files in `/nerves_system_trellis/linux/`.
   - Invokes `make ARCH=arm CROSS_COMPILE=... -C linux/` using `linux_defconfig`.
   - Produces `zImage`, `sun8i-t113s-trellis.dtb`, and any `.ko` modules.
3. The `zImage` and `.dtb` land in `/boot/` on the squashfs rootfs.
4. At boot, U-Boot's extlinux logic loads `/boot/zImage` and `/boot/sun8i-t113s-trellis.dtb` from whichever rootfs slot is active (A or B per Nerves A/B scheme).
5. Kernel boots, parses the DTB, enumerates drivers, mounts the rootfs squashfs, hands control to `/sbin/init` → eventually the BEAM.

Full boot sequence and A/B detail: [bootloader_uboot.md](./bootloader_uboot.md).
Build-system wiring (how the kernel config + patches become the hex package): [nerves_system_trellis.md](./nerves_system_trellis.md).

## 13. When you'd modify this

Virtually never. The defconfig and DTS are stable; changes require a full `nerves_system_trellis` rebuild + hex release, which is expensive and error-prone.

The one realistic case: **adding a new peripheral not already covered by an existing driver / DT node.** Example — bolting on an I²C temperature sensor:

1. Add `&i2c0 { status = "okay"; ... }` and a child node with the sensor's `compatible` string.
2. Enable the matching `CONFIG_SENSORS_XXX=y` (or `=m`) in `linux_defconfig` if not already compiled in.
3. Rebuild `nerves_system_trellis`, bump version, publish.
4. Bump the `name_badge` mix dep.
5. `mix firmware && mix burn` (or OTA).

Other reasons you'd touch this (rare):
- **Enable an already-compiled-but-disabled subsystem** — e.g. PWM: flip `&pwm { status = "okay"; }` in the DTS; driver is already compiled from patches 01–04.
- **Kernel version bump** — follow upstream `nerves_system_trellis` bumps, don't roll your own.

Everything else (GPIO changes, SPI device tweaks at the software level, ADC scaling) happens in user-space Elixir and requires zero kernel/DTS work.

## 14. Recovery scenarios

### Kernel won't boot (A slot corrupt)

Symptom: device power-cycles in a loop, U-Boot console shows kernel-decompress errors or `Bad Linux ARM zImage magic`.

- If B slot is still valid, U-Boot's A/B fallback logic should roll back automatically after a small number of failed boot attempts (Nerves marks boots "validated" once user-space comes up).
- Manual force-revert: interrupt U-Boot, `setenv nerves_fw_active b; saveenv; boot`.
- Worst case: `mix burn` over FEL — see [usb_fel_loaders.md](./usb_fel_loaders.md).

### DTS change bricks peripherals

Symptom: boots to user-space but e-ink, buttons, or WiFi missing; `dmesg` shows driver probe failures.

- Same A/B recovery: revert to previous slot.
- If both slots carry the bad DT (because you flashed twice), FEL-flash a known-good firmware build.

### Kernel or DT totally wedged, no SSH, no console

Enter FEL (power off → hold FEL button → power on → release), then from `usb_fel_loaders/`:

```sh
./launch.sh trellis      # erases eMMC, exposes mass-storage
```

then from `name_badge/`:

```sh
MIX_TARGET=trellis mix burn
```

Full FEL procedure: [usb_fel_loaders.md](./usb_fel_loaders.md).

### Post-reflash hygiene

- `ssh-keygen -R wisteria.local` on the dev host to clear the stale host key.
- Allow 2–3 minutes for first boot — squashfs mount + Erlang boot is slower on a cold device than the "30–60 s" quoted in some docs.
- Clock is wrong until NTP kicks in (needs WiFi). Force: `NervesTime.restart_ntpd()` in IEx.
