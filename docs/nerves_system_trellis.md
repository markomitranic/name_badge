# nerves_system_trellis

Paper documentation for the `nerves_system_trellis` package — the Nerves system (Buildroot-based Linux distribution) that underpins the Protolux Trellis e-ink name badge. Covers layout, Buildroot defconfig, rootfs overlay, erlinit boot, fwup tasks, build flow, toolchain, versioning, and how to consume/modify.

Part of a 5-doc set. See also:
- [name_badge.md](./name_badge.md) — Elixir app that runs on top of this system
- [bootloader_uboot.md](./bootloader_uboot.md) — U-Boot, partition layout, A/B slots, boot flow
- [device_tree_kernel.md](./device_tree_kernel.md) — Linux 6.12.32, DTS, drivers
- [usb_fel_loaders.md](./usb_fel_loaders.md) — USB FEL recovery flashing

---

## Table of Contents

1. [What is a Nerves system](#what-is-a-nerves-system)
2. [What this specific system provides](#what-this-specific-system-provides)
3. [Source repo and versioning](#source-repo-and-versioning)
4. [Architecture overview](#architecture-overview)
5. [The Buildroot defconfig](#the-buildroot-defconfig)
6. [Rootfs overlay](#rootfs-overlay)
7. [Busybox fragment](#busybox-fragment)
8. [fwup tasks](#fwup-tasks)
9. [Build hooks](#build-hooks)
10. [Toolchain](#toolchain)
11. [Build flow](#build-flow)
12. [Artifact cache](#artifact-cache)
13. [Version history](#version-history)
14. [Versioning scheme](#versioning-scheme)
15. [How to consume](#how-to-consume)
16. [Pin / update / force-rebuild](#pin--update--force-rebuild)
17. [When to modify this](#when-to-modify-this)
18. [CI](#ci)
19. [Board provisioning](#board-provisioning)
20. [Recovery scenarios](#recovery-scenarios)
21. [Key files summary](#key-files-summary)

---

## What is a Nerves system

A Nerves **system** is the Linux-side of a Nerves firmware image: a Buildroot-produced, minimal, read-only Linux distribution tailored to a specific board. It contains:

- **Toolchain** — prebuilt cross-compiler targeting the board's ABI.
- **U-Boot** — bootloader, with environment and A/B slot awareness.
- **Kernel** — Linux, board-specific defconfig, DTS, and patches.
- **Rootfs** — Buildroot-built squashfs plus a rootfs overlay providing config files (erlinit, fwup env, hostname, extlinux A/B).
- **`fwup.conf`** — declarative firmware packaging + A/B slot update logic.

A system is **not** the application — it's the substrate. The Elixir/Erlang app (the "release") is placed by `mix firmware` into a separate ext4 application partition that the system mounts at `/root` during boot.

Nerves systems are distributed as hex packages (`type: :system` in `mix.exs`). On first use, `mix deps.compile` either downloads a precompiled artifact from the repo's `artifact_sites` or builds the whole Buildroot tree from source (Linux-only, many hours). Consumer projects pull a system in as an ordinary dependency and select it via `MIX_TARGET=<target>`.

## What this specific system provides

The `nerves_system_trellis` system is tuned for the Protolux Trellis e-ink name badge:

| Layer | Choice |
|---|---|
| SoC | Allwinner T113-S4 (sun8i-r528 variant), dual Cortex-A7 @ 1.2 GHz |
| Arch | ARMv7, 32-bit hard-float, NEON + VFPv4 |
| RAM / Storage | 256 MB DDR3 / eMMC |
| Linux | 6.12.32 custom (patches + DTS in-tree) |
| U-Boot | 2025.04 custom (env size 128 KB at 4 MB offset on eMMC) |
| libc | GLIBC, kernel headers 5.4 |
| Compiler | GCC 13 (via Nerves toolchain 13.2.0) |
| Init | **erlinit** as PID 1 (no sysvinit, no systemd) |
| OTP | OTP 27/28 capable (system is OTP-agnostic; app chooses) |
| Wireless | wpa_supplicant with WPA3, AP mode, mesh, WPS; Realtek firmware bundled |
| GPIO | libgpiod + tools (for e-ink panel control) |
| Runtime | squashfs rootfs + ext4 app partition; fwup A/B updates |

## Source repo and versioning

- **GitHub**: `https://github.com/protolux-electronics/nerves_system_trellis`
- **Current version**: `0.3.0` (from `/nerves_system_trellis/VERSION`)
- **License**: Apache-2.0
- **Hex package**: `nerves_system_trellis`
- **Artifact site**: `{:github_releases, "protolux-electronics/nerves_system_trellis"}` — prebuilt `.tar.xz` per tagged release

## Architecture overview

```
┌───────────────────────────────────────────────────────────────────┐
│                     name_badge.fw (fwup archive)                  │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │  Delivered by: mix firmware (in name_badge/)               │   │
│  │                                                            │   │
│  │   ┌────────────────────────────────────────────────────┐   │   │
│  │   │  OTP release (Elixir app)                          │   │   │
│  │   │     name_badge + deps + BEAM                       │   │   │
│  │   │     → ext4 app partition /dev/mmcblk0p4            │   │   │
│  │   └────────────────────────────────────────────────────┘   │   │
│  │                           on top of                        │   │
│  │   ┌────────────────────────────────────────────────────┐   │   │
│  │   │  nerves_system_trellis (this package)              │   │   │
│  │   │  ┌──────────────────────────────────────────────┐  │   │   │
│  │   │  │  Rootfs overlay                              │  │   │   │
│  │   │  │  /etc/erlinit.config, /etc/fw_env.config,    │  │   │   │
│  │   │  │  /etc/boardid.config, /boot/extlinux/*       │  │   │   │
│  │   │  └──────────────────────────────────────────────┘  │   │   │
│  │   │  ┌──────────────────────────────────────────────┐  │   │   │
│  │   │  │  Buildroot rootfs (squashfs)                 │  │   │   │
│  │   │  │  erlinit, busybox, wpa_supplicant, libgpiod, │  │   │   │
│  │   │  │  fwup ops bundle, rtl firmware, ca-certs     │  │   │   │
│  │   │  └──────────────────────────────────────────────┘  │   │   │
│  │   │  ┌──────────────────────────────────────────────┐  │   │   │
│  │   │  │  Linux kernel 6.12.32 + DTB                  │  │   │   │
│  │   │  │  (sun8i-t113s-trellis.dtb)                   │  │   │   │
│  │   │  └──────────────────────────────────────────────┘  │   │   │
│  │   │  ┌──────────────────────────────────────────────┐  │   │   │
│  │   │  │  U-Boot 2025.04 + env + MBR                  │  │   │   │
│  │   │  └──────────────────────────────────────────────┘  │   │   │
│  │   │        built by                                    │   │   │
│  │   │  ┌──────────────────────────────────────────────┐  │   │   │
│  │   │  │  Buildroot (via nerves_system_br)            │  │   │   │
│  │   │  │  + nerves_toolchain_armv7_..._gnueabihf      │  │   │   │
│  │   │  └──────────────────────────────────────────────┘  │   │   │
│  │   └────────────────────────────────────────────────────┘   │   │
│  └────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────┘
```

Layer ownership:
- **Buildroot**: toolchain integration, kernel build, U-Boot build, package compilation, rootfs tarball, squashfs wrapping.
- **`nerves_system_br`**: glue — turns Buildroot output into a Nerves-compatible system artifact.
- **`nerves_system_trellis`**: Trellis-specific defconfig, overlay, DTS, U-Boot env, fwup rules.
- **`fwup`**: final packaging into a single `.fw` archive.

## The Buildroot defconfig

File: `/nerves_system_trellis/nerves_defconfig`

### Toolchain (external, prebuilt)

```
BR2_arm=y
BR2_cortex_a7=y
BR2_ARM_FPU_NEON_VFPV4=y
BR2_TOOLCHAIN_EXTERNAL=y
BR2_TOOLCHAIN_EXTERNAL_URL=
  https://github.com/nerves-project/toolchains/releases/download/v13.2.0/
  nerves_toolchain_armv7_nerves_linux_gnueabihf-linux_${shell uname -m}-13.2.0-BE3EA83.tar.xz
```

- GCC 13, GLIBC, Linux headers 5.4
- C++, Fortran, OpenMP supported
- Host-arch-aware URL (`${shell uname -m}` → `x86_64` or `aarch64`)

### Init: `BR2_INIT_NONE=y`

No sysvinit, no systemd, no openrc. `erlinit` is PID 1, installed via the `nerves-common` skeleton. This is a Nerves-standard choice and is what lets BEAM be the only userspace concern.

### Rootfs skeleton + overlays

```
BR2_ROOTFS_SKELETON_CUSTOM=y
BR2_ROOTFS_SKELETON_CUSTOM_PATH="${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/skeleton"
BR2_ROOTFS_OVERLAY="${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/rootfs_overlay \
                   ${NERVES_DEFCONFIG_DIR}/rootfs_overlay"
```

Order matters: Trellis overlay is applied **after** nerves-common, so it can override anything.

### Locale

```
BR2_GENERATE_LOCALE="en_US.UTF-8"
BR2_ENABLE_LOCALE_WHITELIST="locale-archive"
```

Keeps only `en_US.UTF-8` in the final image to save space.

### Kernel

Linux 6.12.32 with a custom defconfig, DTS at `/nerves_system_trellis/dts/allwinner/sun8i-t113s-trellis.dts`, and patches in `/nerves_system_trellis/linux/`. Details in [device_tree_kernel.md](./device_tree_kernel.md).

### U-Boot

U-Boot 2025.04 with defconfig + 3 patches + `uboot.env` template (env size **128 KB**). Details in [bootloader_uboot.md](./bootloader_uboot.md).

### Linux firmware blobs (Realtek WiFi)

```
BR2_PACKAGE_LINUX_FIRMWARE=y
BR2_PACKAGE_LINUX_FIRMWARE_RTL_81XX=y
BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX=y
BR2_PACKAGE_LINUX_FIRMWARE_RTL_88XX=y
BR2_PACKAGE_LINUX_FIRMWARE_RTL_RTW88=y
BR2_PACKAGE_LINUX_FIRMWARE_RTL_RTW89=y
```

Covers RTL8188FU (which ships on the badge) plus near-relatives in case board revs swap the chip.

### wpa_supplicant

All security features enabled:

```
BR2_PACKAGE_WPA_SUPPLICANT_WPA3=y
BR2_PACKAGE_WPA_SUPPLICANT_AP_SUPPORT=y
BR2_PACKAGE_WPA_SUPPLICANT_MESH_NETWORKING=y
BR2_PACKAGE_WPA_SUPPLICANT_AUTOSCAN=y
BR2_PACKAGE_WPA_SUPPLICANT_HOTSPOT=y
BR2_PACKAGE_WPA_SUPPLICANT_WPS=y
BR2_PACKAGE_WPA_SUPPLICANT_CTRL_IFACE=y
```

Plus `BR2_PACKAGE_WIRELESS_REGDB=y` and `BR2_PACKAGE_CA_CERTIFICATES=y`.

### Selected packages

| Package | Purpose |
|---|---|
| `libgpiod` (+ tools) | GPIO access library — used by e-ink display driver in userspace |
| `e2fsprogs` (no fsck) | ext4 utilities for app partition (mkfs.ext4) |
| `nbtty` | Better-behaved serial TTY wrapper for erlinit console |
| `nerves_config` | Nerves system glue |
| `host-uboot-tools` | Provides `fw_printenv`/`fw_setenv` with `ENVIMAGE_SIZE=131072` |

### Reproducibility + debug

```
BR2_REPRODUCIBLE=y
BR2_TAR_OPTIONS="--no-same-owner"
BR2_BACKUP_SITE="http://dl.nerves-project.org"
BR2_ENABLE_DEBUG=y
```

`BR2_REPRODUCIBLE=y` + `--no-same-owner` make builds byte-deterministic across hosts. `BR2_BACKUP_SITE` is a fallback mirror when upstream sources vanish.

## Rootfs overlay

Path: `/nerves_system_trellis/rootfs_overlay/`

Layered **after** `nerves-common/rootfs_overlay`, so these files override common defaults where they overlap.

### `etc/erlinit.config` — the most important file in the system

erlinit is the Nerves PID 1 replacement for init. It reads this file, configures the environment, mounts the app partition, sets the hostname, and launches BEAM.

Key options (as configured here):

```
-c ttyS4                                          # console = UART4
--warn-unused-tty                                 # log if another proc opens the tty
-s "/usr/bin/nbtty"                               # wrap terminal via nbtty
--pre-run-exec /usr/sbin/rngd                     # entropy daemon before BEAM
--update-clock                                    # bump clock to build-time minimum
--shutdown-report /data/shutdown.txt              # persist shutdown reason
-e LANG=en_US.UTF-8;LANGUAGE=en;ERL_INETRC=/etc/erl_inetrc
-e ERL_CRASH_DUMP=/root/erl_crash.dump;ERL_CRASH_DUMP_SECONDS=5
-m /dev/mmcblk0p4:/root:ext4:nodev:               # mount app partition at /root
-r /srv/erlang                                    # OTP release path
-d /usr/bin/boardid                               # serial ID discovery script
-n wisteria-%s                                    # hostname format
--boot shoehorn                                   # start shoehorn release first, fallback to main
```

Boot sequence:

1. Kernel hands control to erlinit (PID 1).
2. erlinit reads `/etc/erlinit.config`.
3. erlinit mounts `/dev/mmcblk0p4` (ext4) at `/root` — the application partition.
4. erlinit runs `boardid` (config below) to get a device-unique serial.
5. erlinit sets hostname to `wisteria-<serial>` (first 6–8 chars typically).
6. erlinit launches `/usr/sbin/rngd` to seed the kernel RNG.
7. erlinit starts BEAM with the OTP release at `/srv/erlang`, trying the `shoehorn` release first.
8. If BEAM crashes:
   - Write `erl_crash.dump` to `/root/`
   - Wait 5 seconds (`ERL_CRASH_DUMP_SECONDS=5`)
   - Append shutdown reason to `/data/shutdown.txt`
   - Reboot

The `--update-clock` flag is important: on a freshly powered badge with a dead RTC, the clock may be stuck at the last power-off time. erlinit bumps it forward to at least the firmware's build time, reducing TLS and OTA weirdness before NTP syncs.

### `etc/fw_env.config`

```
/dev/mmcblk0    0x400000    0x20000
```

Tells `fw_printenv` / `fw_setenv` where U-Boot's environment lives on eMMC:
- Offset: **4 MB** (`0x400000`)
- Size: **128 KB** (`0x20000`)

Matches the U-Boot build-time `ENVIMAGE_SIZE=131072`. Used by the running system to read/write U-Boot env at runtime (e.g., flipping `nerves_fw_active` during OTA).

### `etc/boardid.config`

Feeds `/usr/bin/boardid` so it can derive a stable per-device identifier for hostname and MDNS. Tries in order:

1. **ATECC608A crypto chip on I2C-0 at 0x60** — secure element if populated:
   ```
   -b atecc508a -f /dev/i2c-0 -a 0x60 -X
   ```
2. **Sunxi SID fuses** — SoC-burned serial:
   ```
   -b binfile -f /sys/bus/nvmem/devices/sunxi-sid0/nvmem -l 16 -k 0 -n 8
   ```
   Reads 16 bytes, keeps the last 8.

Result becomes `wisteria-<ID>` hostname, discoverable via mDNS as `wisteria-<ID>.local`. If only one badge is on the network, `wisteria.local` also resolves (shortest form from nerves-common).

### `boot/extlinux/extlinux-a.conf` and `extlinux-b.conf`

Two near-identical extlinux configs for A/B slot boot. Each loads:
- `kernel /boot/zImage`
- `fdt /boot/sun8i-t113s-trellis.dtb`
- `append root=/dev/mmcblk0p2 ...` (A) **or** `root=/dev/mmcblk0p3 ...` (B)

U-Boot picks which to load based on `nerves_fw_active`. Full mechanics and partition layout in [bootloader_uboot.md](./bootloader_uboot.md).

## Busybox fragment

File: `/nerves_system_trellis/busybox.fragment`

Single line:

```
CONFIG_DEVMEM=y
```

Enables the `devmem` applet — BusyBox's direct `/dev/mem` read/write utility. Useful for low-level poking during hardware bring-up (e.g., reading Allwinner hardware registers). Not strictly required for production but cheap to leave in.

## fwup tasks

fwup is Nerves' firmware tool: it reads a declarative `.conf`, resources (rootfs, kernel, U-Boot, MBR), and packages them into a single `.fw` archive. At runtime, fwup applies that archive to the device following a named **task**.

### Main firmware: `fwup.conf`

Path: `/nerves_system_trellis/fwup.conf`

Metadata declared:

```
NERVES_FW_PRODUCT       = "Nerves Firmware"
NERVES_FW_PLATFORM      = "trellis"
NERVES_FW_ARCHITECTURE  = "arm"
NERVES_FW_AUTHOR        = "Gus Workman"
NERVES_FW_DEVPATH       = "/dev/mmcblk0"
NERVES_FW_APPLICATION_PART0_DEVPATH = "/dev/mmcblk0p4"
NERVES_FW_APPLICATION_PART0_FSTYPE  = "ext4"
NERVES_FW_APPLICATION_PART0_TARGET  = "/root"
```

- `NERVES_FW_PLATFORM = "trellis"` is an OTA compatibility gate: `.fw` images built for a different platform are refused. This string was renamed `vitis → trellis` in v0.2.0 (breaking for cross-version OTA).

Partition layout (MBR, 4 partitions): see [bootloader_uboot.md](./bootloader_uboot.md).

Tasks declared:

| Task | Purpose |
|---|---|
| `complete` | First-time / factory write. Needs the device unmounted. Writes MBR + U-Boot + fresh env (sets `nerves_fw_active=a`) + rootfs A. Clears rootfs B and the app partition. |
| `upgrade.a` | Running on B, upgrading to A. Writes new U-Boot, new rootfs A (delta-capable), sets `nerves_fw_active=a`, `nerves_fw_validated=0`. |
| `upgrade.b` | Mirror of `upgrade.a`. |
| `upgrade.unvalidated` | Error task; fires if you try to upgrade while current firmware is unvalidated (`nerves_fw_validated=0`). |
| `upgrade.unexpected` | Error task; platform mismatch (e.g., applying a `vitis` or other-system `.fw`). |
| `provision` | Applies provisioning data (uses `NERVES_SERIAL_NUMBER` env to set `nerves_serial_number` in U-Boot env). |

> A comment in `fwup.conf` notes: the device tree is embedded in the U-Boot SPL image. This means firmware upgrades rewrite U-Boot even when only the kernel DT has changed — it's deliberate.

### Runtime ops bundle: `fwup-ops.conf`

Path: `/nerves_system_trellis/fwup-ops.conf`

Compiled during the Buildroot post-build step into `/usr/share/fwup/ops.fw` on the running device. Invoked at runtime as:

```sh
fwup -t <task> -d /dev/rootdisk0 /usr/share/fwup/ops.fw
```

Tasks:

| Task | Effect |
|---|---|
| `factory-reset` | Clear `mmcblk0p4` (app partition), then reboot |
| `prevent-revert.a` | Permanently prevent reverting to B (scrubs B rootfs) |
| `prevent-revert.b` | Mirror |
| `revert.a` | Switch active slot to A (requires A still valid) |
| `revert.b` | Switch active slot to B |
| `validate` | Set `nerves_fw_validated=1` — marks current firmware good; **required before next OTA upgrade is allowed** |
| `status` | Print active partition (`a` or `b`) |

The Elixir app normally calls these via `Nerves.Runtime.revert/0`, `Nerves.Runtime.validate_firmware/0`, etc. — not directly.

## Build hooks

### `post-build.sh` (~14 lines)

Runs after Buildroot builds the target rootfs tree but before it's wrapped into squashfs.

Actions:
1. `mkdir -p $TARGET_DIR/usr/share/fwup/`
2. Compile `fwup-ops.conf` → `$TARGET_DIR/usr/share/fwup/ops.fw`
3. Create `revert.fw → ops.fw` symlink in the same dir (back-compat for older code calling `revert.fw` by name)
4. Copy `fwup_include/` (contains `provisioning.conf`) into `$BINARIES_DIR` for the image-packaging step to pick up

### `post-createfs.sh` (~8 lines)

Invokes the nerves-common post-createfs.sh with this system's `fwup.conf`, which packages squashfs + kernel + DTB + U-Boot + MBR into the final `.fw` file that ends up in `_build/trellis_dev/nerves/images/name_badge.fw`.

### `fwup_include/provisioning.conf`

One line:

```
uboot_setenv(uboot-env, "nerves_serial_number", "${NERVES_SERIAL_NUMBER}")
```

At burn time, if you set `NERVES_SERIAL_NUMBER=XXX` in the environment, the U-Boot env on the target gets `nerves_serial_number=XXX` written into it. The Elixir app reads it via `Nerves.Runtime.KV.get("nerves_serial_number")` for factory provisioning workflows.

## Toolchain

Package: `nerves_toolchain_armv7_nerves_linux_gnueabihf`, pinned in `mix.exs` as `~> 13.2.0`.

| Attribute | Value |
|---|---|
| GCC | 13 |
| GLIBC | yes |
| Kernel headers | 5.4 |
| Tuple | `armv7-nerves-linux-gnueabihf` |
| CPU | Cortex-A7 |
| FPU | NEON + VFPv4 |
| Float ABI | Hard-float |
| Distribution | Prebuilt tarball from `github.com/nerves-project/toolchains` |

`TARGET_GCC_FLAGS` (from `mix.exs`) passed to Buildroot:

```
-mabi=aapcs-linux -mfpu=neon-vfpv4 -marm -fstack-protector-strong \
-mfloat-abi=hard -mcpu=cortex-a7 -fPIE -pie -Wl,-z,now -Wl,-z,relro
```

Note the hardening flags: PIE, full RELRO, stack protector. These flow into every userspace binary built by Buildroot.

## Build flow

When the consumer project (`name_badge`) runs `mix firmware`:

1. `name_badge/mix.exs` declares `{:nerves_system_trellis, "~> 0.3.0", runtime: false, targets: :trellis}`.
2. `MIX_TARGET=trellis` is set (via `name_badge/mise.toml` in this workspace).
3. `mix deps.compile` triggers `Nerves.Package.Compiler` for `nerves_system_trellis`.
4. Nerves checks `artifact_sites` (GitHub releases) for a precompiled tarball matching the current host (`linux_x86_64` or `linux_aarch64`). macOS hosts **cannot** build from source — they always download the prebuilt artifact.
5. If present: download `.tar.xz` into `~/.nerves/artifacts/nerves_system_trellis-portable-<version>-<hash>/`, extract, done.
6. If absent (Linux host only): Buildroot runs from scratch:
   - Fetch toolchain tarball
   - Fetch kernel, U-Boot, Buildroot package sources
   - Apply patches (kernel + U-Boot)
   - Build everything
   - Produce rootfs squashfs + kernel Image + DTB + U-Boot images
   - Hours. Tens of GB of disk.
7. `mix firmware` assembles the final `.fw`: pulls the system artifact (rootfs, kernel, DTB, U-Boot, `fwup.conf`, `provisioning.conf`), adds the OTP release of the Elixir app, and invokes `fwup -c -f fwup.conf` to package.
8. Output: `_build/trellis_dev/nerves/images/name_badge.fw`

## Artifact cache

Prebuilt system artifacts live in `~/.nerves/artifacts/`. Hex does **not** ship the system itself — it ships the `mix.exs` + defconfig + scripts. The heavy binary output is served from the repo's GitHub releases, keyed by version and host arch.

Cache entries look like:
```
~/.nerves/artifacts/nerves_system_trellis-portable-0.3.0-<sha>/
```

To invalidate and force re-download: `rm -rf ~/.nerves/artifacts/`. Next `mix deps.compile` repopulates.

## Version history

From `/nerves_system_trellis/CHANGELOG.md`:

| Version | Notable |
|---|---|
| **0.3.0** | Bump `nerves_system_br`; relaxed fwup platform checks (smooths upgrades from 0.2.0) |
| **0.2.0** | Bump `nerves` + `nerves_system_br`; OTP 28 + Elixir 1.19 support; **platform renamed from `vitis` to `trellis`** (breaking for OTA across this boundary) |
| **0.1.1** | Added RTL8723 WiFi firmware blobs |
| **0.1.0** | Initial release |

The `vitis → trellis` rename in 0.2.0 is the most important fact: any badge still on 0.1.x firmware cannot be OTA'd to 0.2.x+ (fwup will reject the image as platform-incompatible). Such badges need a USB FEL reflash. See [usb_fel_loaders.md](./usb_fel_loaders.md).

## Versioning scheme

**Not strict SemVer.** Maintainer conventions:

| Bump | Trigger |
|---|---|
| Major | Breaking build-infra change (rare; none yet — still pre-1.0) |
| Minor | Buildroot / Erlang / OTP / Linux major release bumps (quarterly-ish) |
| Patch | Buildroot minor updates, OTP/kernel point updates, bug fixes, firmware blob additions |

Consumers should not assume that a minor bump is non-breaking at the app level — e.g., 0.1 → 0.2 broke OTA upgrades via the platform rename. Always read the CHANGELOG before bumping across a minor.

## How to consume

In the consumer project's `mix.exs` (see [name_badge.md](./name_badge.md) for the full file):

```elixir
def deps do
  [
    # ... other deps
    {:nerves_system_trellis, "~> 0.3.0", runtime: false, targets: :trellis}
  ]
end
```

And environment:

```sh
MIX_TARGET=trellis mix deps.get
MIX_TARGET=trellis mix firmware
```

`name_badge/mise.toml` already pins `MIX_TARGET=trellis` for every command run in that directory, so the env var is normally automatic.

For the **host simulator**: `MIX_TARGET=host` bypasses this system entirely and runs the Elixir app against a host-Elixir toolchain instead.

## Pin / update / force-rebuild

| Action | Command |
|---|---|
| Pin | `~> 0.3.0` in `mix.exs` + `mix.lock` (already the case) |
| Update within constraint | `mix deps.update nerves_system_trellis && mix deps.get && mix firmware` |
| Force recompile | `mix deps.compile nerves_system_trellis --force` (only needed if artifact site is down or host arch is unsupported) |
| Clear artifact cache | `rm -rf ~/.nerves/artifacts` (next build re-downloads) |
| Full nuke | `rm -rf _build deps ~/.nerves/artifacts && mix deps.get && mix firmware` |

The "full nuke" is the standard recovery from cross-arch `_build` corruption (host → trellis or trellis → host switches).

## When to modify this

Almost never. The exceptions:

1. **Need an extra Buildroot package** (e.g., a specific userspace library not enabled upstream).
2. **Need a kernel patch or config tweak** (e.g., enabling a driver).
3. **Need to change something in the rootfs overlay** (e.g., different erlinit flags, different hostname format).

In any of those cases:

1. Fork `protolux-electronics/nerves_system_trellis` on GitHub.
2. Make changes on a branch.
3. Point your consumer project at the fork:
   ```elixir
   {:nerves_system_trellis,
    github: "<your-fork>/nerves_system_trellis",
    branch: "main",
    runtime: false,
    targets: :trellis}
   ```
4. First build **must** be on a Linux host (macOS cannot cross-build the Buildroot tree from scratch). Expect hours and ~20–40 GB of disk.
5. Maintain the fork by rebasing onto upstream when new tagged versions land.

For local iteration without a fork, use `path:` in `mix.exs`:

```elixir
{:nerves_system_trellis, path: "../nerves_system_trellis", ...}
```

Both `github:` and `path:` paths disable artifact caching — every change triggers a re-build.

## CI

CircleCI config: `/nerves_system_trellis/.circleci/config.yml`.

Workflow:

```
get-br-dependencies
    ↓
build-system
    ↓
deploy-system   (only runs on tags matching v.*)
```

- Built on `build-tools/nerves-system-br v1.33.3` (CircleCI orb)
- Elixir 1.19.5, OTP 28
- `deploy-system` pushes the produced `.tar.xz` artifact to the GitHub Release matching the git tag, where `artifact_sites` can fetch it.

Contributor workflow: open a PR → CI builds and verifies → maintainer tags `v0.3.1` (etc.) → deploy job publishes the artifact.

## Board provisioning

At burn time:

```sh
NERVES_SERIAL_NUMBER=ABC123 mix burn
```

This populates the `provision` task defined in `fwup.conf`, which runs `provisioning.conf`:

```
uboot_setenv(uboot-env, "nerves_serial_number", "${NERVES_SERIAL_NUMBER}")
```

Result: U-Boot env on the device gets `nerves_serial_number=ABC123`. The Elixir app reads it via:

```elixir
Nerves.Runtime.KV.get("nerves_serial_number")
```

This is distinct from the `boardid`-derived hostname suffix (which comes from the SID fuses / ATECC crypto chip — immutable). The serial number is a soft factory ID that can be rewritten.

## Recovery scenarios

### New system version boots to kernel panic

If the OTA installed firmware hasn't been validated yet (`nerves_fw_validated=0`), U-Boot's bootcount logic will auto-revert after a few failed boots. Manual recovery:

```sh
# from the running system (if it boots far enough to get an IEx):
iex> Nerves.Runtime.revert()

# or from shell:
$ fwup -t revert.a -d /dev/rootdisk0 /usr/share/fwup/ops.fw   # if currently on B
$ fwup -t revert.b -d /dev/rootdisk0 /usr/share/fwup/ops.fw   # if currently on A
```

### Both slots corrupt / kernel will not boot at all

Full USB FEL reflash. See [usb_fel_loaders.md](./usb_fel_loaders.md) and [bootloader_uboot.md](./bootloader_uboot.md).

### System boots but app is wedged / data corrupt

Clean the application partition while preserving system slots:

```sh
$ fwup -t factory-reset -d /dev/rootdisk0 /usr/share/fwup/ops.fw
```

Or from IEx:

```elixir
iex> Nerves.Runtime.Reboot.reboot_into_loader()   # or app-specific reset helpers
```

### Post-upgrade, need to mark firmware good

```sh
$ fwup -t validate -d /dev/rootdisk0 /usr/share/fwup/ops.fw
```

Or (more idiomatic):

```elixir
iex> Nerves.Runtime.validate_firmware()
```

Without this, the **next** OTA upgrade will be blocked by `upgrade.unvalidated`.

## Key files summary

For future AI consumption without the source repo present:

```
nerves_system_trellis/
├── VERSION                              # 0.3.0
├── mix.exs                              # Nerves package config (see below)
├── CHANGELOG.md                         # See Version history section
├── LICENSE                              # Apache-2.0
├── nerves_defconfig                     # Buildroot config
├── fwup.conf                            # Main firmware tasks + partition layout
├── fwup-ops.conf                        # Runtime ops (validate/revert/factory-reset)
├── post-build.sh                        # Compile ops.fw into target rootfs
├── post-createfs.sh                     # Package final .fw via fwup
├── busybox.fragment                     # CONFIG_DEVMEM=y
├── linux/
│   ├── defconfig                        # Kernel 6.12.32 config
│   └── *.patch                          # 4 kernel patches
├── dts/allwinner/
│   └── sun8i-t113s-trellis.dts          # Board-specific device tree
├── uboot/
│   ├── defconfig                        # U-Boot 2025.04 config
│   ├── *.patch                          # 3 U-Boot patches
│   └── uboot.env                        # Default env template
├── rootfs_overlay/
│   ├── boot/extlinux/extlinux-a.conf    # A-slot boot entry
│   ├── boot/extlinux/extlinux-b.conf    # B-slot boot entry
│   ├── etc/erlinit.config               # PID-1 config (the most important file)
│   ├── etc/fw_env.config                # U-Boot env location for runtime
│   └── etc/boardid.config               # Serial-derivation rules
├── fwup_include/
│   └── provisioning.conf                # NERVES_SERIAL_NUMBER → U-Boot env
└── .circleci/config.yml                 # CI: build + release on v.* tags
```

### `mix.exs` at a glance

```elixir
def project do
  [
    app: :nerves_system_trellis,
    version: @version,                                # read from VERSION file
    elixir: "~> 1.17",
    compilers: Mix.compilers() ++ [:nerves_package],
    nerves_package: nerves_package(),
    deps: deps(),
    # ...
  ]
end

defp nerves_package do
  [
    type: :system,
    platform: Nerves.System.BR,
    platform_config: [defconfig: "nerves_defconfig"],
    artifact_sites: [{:github_releases, "protolux-electronics/nerves_system_trellis"}],
    build_runner_opts: [make_args: ["source", "all", "legal-info"]],
    env: [
      TARGET_ARCH: "arm",
      TARGET_CPU: "cortex_a7",
      TARGET_OS: "linux",
      TARGET_ABI: "gnueabihf",
      TARGET_GCC_FLAGS: """
      -mabi=aapcs-linux -mfpu=neon-vfpv4 -marm -fstack-protector-strong \
      -mfloat-abi=hard -mcpu=cortex-a7 -fPIE -pie \
      -Wl,-z,now -Wl,-z,relro
      """
    ]
  ]
end

defp deps do
  [
    {:nerves, "~> 1.11", runtime: false},
    {:nerves_system_br, "1.33.5", runtime: false},
    {:nerves_toolchain_armv7_nerves_linux_gnueabihf, "~> 13.2.0", runtime: false},
    {:nerves_system_linter, "~> 0.4", runtime: false, only: [:dev, :test]},
    {:ex_doc, "~> 0.22", runtime: false, only: [:docs]}
  ]
end
```

---

## Cross-reference index

- Partition layout, U-Boot env variables, A/B slot boot selection → [bootloader_uboot.md](./bootloader_uboot.md)
- Kernel defconfig, device tree, driver list, userspace-visible devices → [device_tree_kernel.md](./device_tree_kernel.md)
- The Elixir app that lives on top of this system (entry points, OTA integration, screens) → [name_badge.md](./name_badge.md)
- USB FEL recovery flashing when both slots are bricked → [usb_fel_loaders.md](./usb_fel_loaders.md)
