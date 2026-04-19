# Bootloader: U-Boot 2025.04 + SPL (Trellis / T113-S4)

Paper reference for the bootloader layer of the Protolux Trellis badge. The live source tree (`nerves_system_trellis/uboot/`) will be deleted; this doc preserves enough detail to reconstruct the boot stack without it.

Sibling docs in this set:
- [device_tree_kernel.md](./device_tree_kernel.md)
- [nerves_system_trellis.md](./nerves_system_trellis.md)
- [usb_fel_loaders.md](./usb_fel_loaders.md)
- [elixir_application.md](./elixir_application.md)

---

## Table of Contents

1. [What U-Boot is](#1-what-u-boot-is)
2. [What the SPL is and why it's separate](#2-what-the-spl-is-and-why-its-separate)
3. [Boot sequence on Trellis](#3-boot-sequence-on-trellis)
4. [The specific U-Boot build used here](#4-the-specific-u-boot-build-used-here)
5. [eMMC partition layout](#5-emmc-partition-layout)
6. [A/B firmware selection mechanism](#6-ab-firmware-selection-mechanism)
7. [extlinux-a.conf vs extlinux-b.conf](#7-extlinux-aconf-vs-extlinux-bconf)
8. [U-Boot environment access at runtime](#8-u-boot-environment-access-at-runtime)
9. [FEL mode](#9-fel-mode)
10. [Upstream provenance](#10-upstream-provenance)
11. [When you'd need to touch this](#11-when-youd-need-to-touch-this)
12. [Recovery: "I think U-Boot is broken"](#12-recovery-i-think-u-boot-is-broken)

---

## 1. What U-Boot is

U-Boot ("Das U-Boot") is the second-stage bootloader that runs between the SoC's on-chip Boot ROM (BROM) and the Linux kernel on virtually every embedded ARM board. Its responsibilities on Trellis:

- Finish hardware init the SPL didn't do (USB, MMC driver stack beyond the SPL's minimal one, environment subsystem).
- Read its environment (persistent key/value blob) from eMMC.
- Decide which firmware slot (A or B) to boot based on env vars set by Nerves / `fwup`.
- Load the kernel (`zImage`) and Flattened Device Tree (`.dtb`) from the selected slot's squashfs into DRAM.
- Hand off to the kernel with a `bootargs` string.

Nothing Trellis-specific about U-Boot's *role*; what's Trellis-specific is the defconfig, three sunxi patches, and the sunxi extlinux flow that reads A/B configs from the rootfs.

## 2. What the SPL is and why it's separate

**SPL** = **Secondary Program Loader**, a stripped-down U-Boot build that fits in the tiny scratchpad SRAM the Allwinner BROM can load into. On T113-S4 the BROM loads at most a few tens of KB of code before DRAM is initialized — full U-Boot (~500 KB+) does not fit in SRAM.

The SPL's job:

1. Run from SRAM.
2. Configure the DRAM controller using the timing values baked into the build (see `CONFIG_DRAM_*` in [§4](#4-the-specific-u-boot-build-used-here)).
3. Load the full `u-boot.bin` from eMMC (or FEL) into DRAM.
4. Jump to it.

On sunxi the SPL and main U-Boot are glued into a single artifact: `u-boot-sunxi-with-spl.bin`. That is the file written to eMMC offset 8 KB. The BROM knows to look for an eGON.BT0-tagged blob there; eGON.BT0 is the SPL header magic.

### Why not merge SPL and U-Boot?

Physical constraint:
- SRAM A1 on this SoC family is on the order of tens of KB. The full U-Boot image is hundreds of KB and needs to run from DRAM once it's initialized.
- You cannot initialize DRAM from DRAM — the code that initializes DRAM must run from a RAM that's already up (SRAM).
- Therefore: a small SRAM-resident first stage (SPL) brings up DRAM, then loads the large DRAM-resident second stage (U-Boot proper).

Operational consequence: the SPL is the piece most sensitive to hardware details (DRAM timing, clock tree, pinmux), and it's the piece most likely to go silent if misconfigured — because if it crashes before enabling UART, you get no diagnostics at all. The UART4 patch (0001) is what makes diagnostic output possible on this board.

## 3. Boot sequence on Trellis

Step-by-step, cold boot:

| Step | Actor | Action |
|---|---|---|
| 1 | SoC | Power applied. ARM Cortex-A7 core 0 comes out of reset. Core starts executing BROM at reset vector. |
| 2 | BROM | Probes boot media in order: eMMC → SD card → SPI NOR → USB (FEL). Looks for eGON.BT0 magic. |
| 3 | BROM | Finds SPL at eMMC sector 16 (byte offset 8 KB). Copies it into SRAM A1 (base `0x00020000` on sun8i-r528 family). Jumps to it. |
| 4 | SPL | Board init: clocks, pinmux for UART4 console, MMC driver. Brings up DRAM controller at 936 MHz with the TPR timing values from defconfig. |
| 5 | SPL | Loads full U-Boot (`u-boot.bin`) from eMMC into DRAM at `CONFIG_SYS_TEXT_BASE` (sunxi default `0x4a000000`). Jumps to it. |
| 6 | U-Boot | Full init: USB stack, filesystem drivers (incl. squashfs), environment subsystem. Reads env from `/dev/mmcblk0` offset `0x400000`, size `0x20000` (128 KB). |
| 7 | U-Boot | Runs `bootcmd`. Sunxi default is the `distro_bootcmd` / extlinux flow: scan `mmc 0:1` for `/boot/extlinux/extlinux.conf`. On Trellis the env-driven logic picks `extlinux-a.conf` or `extlinux-b.conf` based on `nerves_fw_active`. |
| 8 | U-Boot | Loads `zImage` into `0x42000000`, DTB into `0x43000000`. Appends `append` line from the chosen extlinux config as kernel cmdline. |
| 9 | U-Boot | Runs `CONFIG_BOOTCOMMAND`: `bootz 0x42000000 0:0 0x43000000`. No ramdisk (`0:0`). |
| 10 | Kernel | Linux starts, decompresses, runs with e.g. `console=ttyS4,115200 root=/dev/mmcblk0p2 rootfstype=squashfs rootwait`. |

FEL branch: if in step 3 the BROM cannot find a valid SPL *or* the FEL button forces FEL mode, the BROM instead waits for USB commands on the OTG controller. See [§9](#9-fel-mode).

### Known memory addresses

| Address | Purpose |
|---|---|
| `0x00020000` | SRAM A1 base (SPL load target) |
| `0x40000000` | DRAM base on T113-S4 |
| `0x42000000` | Kernel (`zImage`) load address |
| `0x43000000` | DTB load address |
| `0x4a000000` | U-Boot proper (`CONFIG_SYS_TEXT_BASE`) |

### UART4 pinout (console)

| Signal | SoC pin | Direction | Notes |
|---|---|---|---|
| TX | PD7 | out (SoC → host) | serial output, what you see in a terminal |
| RX | PD8 | in (host → SoC) | keyboard input to U-Boot / login shell |

Baud: **115200 8N1**, no flow control. Both SPL, U-Boot proper, and the Linux kernel all use this same UART (`console=ttyS4,115200` on the kernel cmdline).

## 4. The specific U-Boot build used here

- **Version:** U-Boot **2025.04**
- **Defconfig file:** `nerves_system_trellis/uboot/uboot_defconfig`
- **Patches dir:** `nerves_system_trellis/uboot/` (three `.patch` files)

### Defconfig highlights

```
CONFIG_ARM=y
CONFIG_ARCH_SUNXI=y
CONFIG_MACH_SUN8I_R528=y
CONFIG_DEFAULT_DEVICE_TREE="sun8i-t113s-trellis"

CONFIG_SPL=y

# DRAM timing (T113-S4, 256 MB DDR3 @ 936 MHz)
CONFIG_DRAM_CLK=936
CONFIG_DRAM_SUNXI_ODT_EN=0
CONFIG_DRAM_SUNXI_TPR0=0x004a2195
CONFIG_DRAM_SUNXI_TPR11=0x340000
CONFIG_DRAM_SUNXI_TPR12=0x46
CONFIG_DRAM_SUNXI_TPR13=0x34000100
CONFIG_DRAM_ZQ=8092667

# Console on UART4 (pins PD7/PD8), 115200 baud
CONFIG_CONS_INDEX=5

# Environment: 128 KB blob on eMMC at 4 MB
CONFIG_ENV_SIZE=0x20000
CONFIG_ENV_OFFSET=0x400000
CONFIG_ENV_IS_IN_MMC=y

# Boot command: zImage @ 0x42000000, no initrd, DTB @ 0x43000000
CONFIG_BOOTCOMMAND="bootz 0x42000000 0:0 0x43000000"

# USB gadget identity (used in FEL Mass Storage mode)
CONFIG_USB_GADGET_MANUFACTURER="Trellis USB FEL Loader"
CONFIG_CMD_USB_MASS_STORAGE=y

# Read squashfs rootfs for extlinux
CONFIG_FS_SQUASHFS=y
```

Note: `CONFIG_DEFAULT_DEVICE_TREE="sun8i-t113s-trellis"` refers to the **U-Boot** device tree, compiled from U-Boot's own `arch/arm/dts/` sources (via the sunxi patches). This is distinct from the Linux kernel DT, which lives in `nerves_system_trellis/linux-patches/` — see [device_tree_kernel.md](./device_tree_kernel.md). Both DTs describe the same hardware, but each is consumed by its own binary.

### The three sunxi patches

All three live in `nerves_system_trellis/uboot/` and are applied on top of stock v2025.04.

#### `0001-sunxi-support-uart4-console-output.patch`
Adds GPIO pinmux setup for UART4 on pins **PD7/PD8**. Gate: `CONFIG_CONS_INDEX == 5 && CONFIG_MACH_SUN8I_R528`. Without this, setting `CONFIG_CONS_INDEX=5` in defconfig produces a silent U-Boot (no serial output) because the pins are never muxed to the UART controller.

#### `0002-Turn-off-DRAM-remapping-for-T113-S4.patch`
Patches `drivers/ram/sunxi/dram_sun20i_d1.c`. The T113-S4 DDR controller silicon requires DRAM remapping **disabled**. Stock U-Boot's fuse-to-remap-table lookup picks remap table 5 for fuse value 10 (T113-S4 ID); the patch changes this to remap table **0** (effectively "no remap"). Without the patch, DRAM init succeeds but produces intermittent memory corruption — boots start but crash unpredictably. Hard requirement.

#### `0003-Support-environment-in-MMC-when-booted-in-FEL-mode.patch`
Normally, when U-Boot is loaded via FEL (USB), its MMC env backend treats eMMC as unavailable. This patch removes that restriction so `fw_printenv` / `fw_setenv` / `env save` work in FEL-loaded U-Boot the same way they do in eMMC-booted U-Boot. Enables the recovery flow where the `usb_fel_loaders` tool uploads a custom U-Boot into DRAM, and that U-Boot exposes eMMC as USB Mass Storage *and* can edit env. See [usb_fel_loaders.md](./usb_fel_loaders.md).

## 5. eMMC partition layout

Source of truth: `nerves_system_trellis/fwup.conf`.

Sector size is 512 bytes. All offsets are byte-exact from that file.

| Region | Offset (sector) | Offset (bytes) | Size (sectors) | Size (bytes) | Purpose |
|---|---|---|---|---|---|
| MBR | 0 | 0 | 1 | 512 B | Master Boot Record (partition table only) |
| U-Boot + SPL | 16 | 8 KB | 8176 | ~4 MB | `u-boot-sunxi-with-spl.bin` |
| U-Boot env | 8192 | 4 MB | 256 | 128 KB | Environment blob (`CONFIG_ENV_OFFSET`) |
| Rootfs A (MBR p1) | 43008 | 21 MB | 286720 | 140 MB | kernel + squashfs, slot A |
| Rootfs B (MBR p2) | 329728 | 161 MB | 286720 | 140 MB | kernel + squashfs, slot B |
| Application (MBR p3) | 616448 | 301 MB | 1048576 | 512 MB | ext4 writable, resizable to fill eMMC |

Layout diagram (not to scale):

```
0           8 KB      4 MB              21 MB                  161 MB                     301 MB                      ~813 MB (min)
|  MBR  |  U-Boot+SPL |   env (128 KB) |  rootfs A (140 MB)  |  rootfs B (140 MB)  |  application ext4 (512 MB+)  |  free/expand
  p1 (?)       raw          raw                p1                    p2                        p3
```

Notes:
- Minimum eMMC size: ~1 GB (there is 1 GB eMMC on production Trellis; fwup leaves the application partition expandable by erlinit on first boot).
- The MBR has **three** primary partitions: rootfs A (p1), rootfs B (p2), application (p3). U-Boot and env live *outside* any partition — raw sector ranges.
- `NERVES_FW_APPLICATION_PART0_DEVPATH` in fwup.conf is actually `/dev/mmcblk0p3`. (Earlier versions of this note referenced `p4`; current `fwup.conf` uses `p3` since there are only three partitions. Verify against live fwup.conf before trusting.)
- Application partition is mounted at `/root` (ext4) by erlinit.
- Device node for the eMMC: `/dev/mmcblk0`.

**Quirk** (from a comment in `fwup.conf`): the **kernel device tree is packed inside the U-Boot image** (`u-boot.toc1` / `u-boot-sunxi-with-spl.bin`), not inside the rootfs. Therefore a firmware upgrade that changes only the kernel DT still has to rewrite the U-Boot region. Minor operational consequence: you cannot push a DT-only update as a rootfs-only A/B swap.

## 6. A/B firmware selection mechanism

Goal: robust OTA. An update writes the *inactive* slot, flips the active-slot pointer, reboots. If the new slot doesn't come up cleanly, U-Boot reverts (or Nerves marks it invalid and reverts on next boot).

### Where the selection lives

- Storage: U-Boot env blob on `/dev/mmcblk0` at offset `0x400000`, size `0x20000` (128 KB).
- Keys (canonical Nerves set):
  - `nerves_fw_active` — `"a"` or `"b"`. Which slot the next boot should use.
  - `nerves_fw_validated` — `"0"` or `"1"`. Set to `1` by the application after it confirms the new image works; U-Boot reverts if unvalidated after a reboot.
  - `nerves_fw_booted` — boot-counter / marker, incremented by U-Boot on each boot attempt.
  - `nerves_serial_number` — device identity.
  - Plus `a.nerves_fw_*` / `b.nerves_fw_*` groups for per-slot metadata (product, version, platform, architecture, author, description, vcs_identifier, misc).

### Flow

1. Device is running slot A. `nerves_fw_active=a`, `nerves_fw_validated=1`.
2. `fwup` receives an update. Writes the new image to slot B (rootfs partition p2). Sets `nerves_fw_active=b`, `nerves_fw_validated=0`.
3. Reboot. U-Boot reads env, sees `a`/`b` pointer = `b`, picks `extlinux-b.conf`, boots rootfs B.
4. Application starts, checks health, calls `Nerves.Runtime.validate_firmware()` which sets `nerves_fw_validated=1`.
5. If validation doesn't happen (crash loop, watchdog reboots), on next boot U-Boot (or the early boot script) can revert `nerves_fw_active` back to `a`. Exact revert-on-unvalidated logic depends on the bootcmd/hooks used; Nerves' default on most platforms is to require explicit validation within a boot window.

### How U-Boot picks the slot

Sunxi's standard `distro_bootcmd` runs an extlinux scan. The Trellis firmware relies on env substitution: the extlinux conf path (or the chosen file) is determined by `nerves_fw_active`. Practically, both `/boot/extlinux/extlinux-a.conf` and `extlinux-b.conf` exist inside *each* rootfs (they're overlay files), and the bootcmd script reads one or the other based on the env var.

### Revert semantics

Failure-to-validate revert flow (idealised — exact hooks may vary by Nerves release):

1. fwup writes slot B, sets `nerves_fw_active=b`, `nerves_fw_validated=0`, optionally `nerves_fw_booted=0`.
2. First boot into B. U-Boot increments a boot-counter env var (or the app-layer does).
3. If the app calls `Nerves.Runtime.validate_firmware()` successfully, `nerves_fw_validated=1` is persisted. Future reboots stick with B.
4. If the device reboots before validation (crash, watchdog, power pull), on the next boot the bootcmd logic sees `nerves_fw_validated=0` plus a high boot-counter and flips `nerves_fw_active` back to `a`.
5. The broken slot B image stays on eMMC (but is no longer pointed to) until the next OTA overwrites it.

Keys of interest in env for A/B + metadata:

| Key | Value | Set by |
|---|---|---|
| `nerves_fw_active` | `a` / `b` | fwup (on upgrade), `Nerves.Runtime.KV.put/2`, U-Boot (on revert) |
| `nerves_fw_validated` | `0` / `1` | Nerves app via `validate_firmware()`; fwup resets to `0` on upgrade |
| `nerves_fw_booted` | `0` / `1` (or counter) | U-Boot / early userspace |
| `nerves_fw_devpath` | e.g. `/dev/mmcblk0` | fwup, used by runtime tools |
| `nerves_serial_number` | hardware UID | provisioning |
| `a.nerves_fw_product` / `b.nerves_fw_product` | "name_badge" | fwup per-slot metadata |
| `a.nerves_fw_version` / `b.nerves_fw_version` | e.g. "0.3.1" | fwup per-slot metadata |
| `a.nerves_fw_platform` / `b.nerves_fw_platform` | "trellis" | fwup per-slot metadata |
| `a.nerves_fw_architecture` / `b.nerves_fw_architecture` | "arm" | fwup per-slot metadata |
| `a.nerves_fw_uuid` / `b.nerves_fw_uuid` | fwup UUID | fwup per-slot metadata |

## 7. extlinux-a.conf vs extlinux-b.conf

Location in source: `nerves_system_trellis/board/nervesbsd/trellis/rootfs_overlay/boot/extlinux/` (path convention — exact path is whatever `rootfs_overlay/boot/extlinux/` resolves to on the target).

Runtime path on device: `/boot/extlinux/extlinux-a.conf` and `/boot/extlinux/extlinux-b.conf`, embedded in each slot's squashfs.

### `extlinux-a.conf`
```
label linux
  kernel /boot/zImage
  fdt /boot/sun8i-t113s-trellis.dtb
  append console=ttyS4,115200 root=/dev/mmcblk0p2 rootfstype=squashfs rootwait
```

### `extlinux-b.conf`
Identical except:
```
  append console=ttyS4,115200 root=/dev/mmcblk0p3 rootfstype=squashfs rootwait
```

Key differences:
- **`root=` partition** — A boots from `/dev/mmcblk0p2` (wait: see partition table in §5; p1 is rootfs A, p2 is rootfs B — but the extlinux `root=` values say p2 for slot A and p3 for slot B). Resolution: Linux numbers mmcblkXpN from 1; MBR primary partitions map 1→p1, 2→p2, 3→p3. If rootfs A is MBR p1, it mounts as `/dev/mmcblk0p1` in Linux, not p2. The `extlinux-a.conf` example above (`root=/dev/mmcblk0p2`) matches a layout where A = p2 and B = p3 — which is consistent with older Nerves layouts that use p1 for boot/boot_a or for a small boot partition. **Trust the live `extlinux-*.conf` on the running device over the table in §5 for kernel cmdline purposes.** The §5 table is from `fwup.conf` byte offsets, which are layout-correct; the *device node numbering* is what the extlinux configs declare, and they are the ground truth for the kernel's `root=`.

Other notes:
- `kernel /boot/zImage` — path is inside the rootfs squashfs.
- `fdt /boot/sun8i-t113s-trellis.dtb` — this is the **kernel** DTB, not U-Boot's DT.
- `console=ttyS4,115200` — same UART as U-Boot (PD7/PD8).
- No `initrd` line; the kernel mounts squashfs directly.

## 8. U-Boot environment access at runtime

From a booted Linux system (or from a Nerves IEx shell on the badge), you read/write the same env blob that U-Boot uses at boot via `fw_printenv` / `fw_setenv`.

### Config file
`/etc/fw_env.config` on the device:
```
/dev/mmcblk0    0x400000    0x20000
```

Columns: device, offset, size. Must match `CONFIG_ENV_OFFSET` and `CONFIG_ENV_SIZE` exactly.

### Binaries
`fw_printenv` and `fw_setenv` are provided by `host-uboot-tools` via Buildroot. They are part of the Nerves system rootfs.

### Examples
```sh
fw_printenv                         # dump all env vars
fw_printenv nerves_fw_active        # one var
fw_setenv nerves_fw_active b        # flip slot
fw_setenv nerves_fw_validated 1     # mark validated
fw_setenv some_key                  # unset (no value)
```

### From Elixir / Nerves
```elixir
Nerves.Runtime.KV.get_all()                 # %{"nerves_fw_active" => "a", ...}
Nerves.Runtime.KV.get("nerves_fw_active")
Nerves.Runtime.KV.put("nerves_fw_active", "b")
Nerves.Runtime.validate_firmware()          # sets nerves_fw_validated=1
```

Under the hood `Nerves.Runtime.KV` talks to the same env blob via the same `fw_env.config`.

### Atomicity and corruption

- U-Boot writes the env as a CRC-prefixed blob. If a write is interrupted (power loss mid-write), the CRC fails and U-Boot falls back to compiled-in defaults on next boot — you will lose `nerves_fw_active` and friends.
- There is **no redundant env** on Trellis (no second env copy at a different offset). If you need redundancy, you would enable `CONFIG_SYS_REDUNDAND_ENVIRONMENT=y` and provide a second offset. This is a deliberate simplification on this board — the env is rarely written during normal operation.
- `fw_setenv` writes the full blob, not just the changed key. Concurrent writes from two processes are a bad idea; serialize through a single writer (typically `Nerves.Runtime.KV`).

## 9. FEL mode

FEL is Allwinner's built-in USB recovery protocol. The BROM exposes a tiny USB device-mode stack that accepts memory read/write and execute commands. It's the "bricked device recovery" interface and also the *normal* first-flash path.

### Triggers
1. **Hold the FEL button during power-on.** Explicit force.
2. **BROM cannot find a valid SPL** on any boot source. Implicit fallback — useful if eMMC is blank or corrupted.

### What's exposed
- USB OTG on USB0 (the USB-C connector). Device acts as a USB client.
- `sunxi-fel` tooling on the host (from `sunxi-tools`) talks to it: read/write DRAM, read/write eMMC (via uploaded SPL that handles it), execute loaded code.

### Typical uses
- **First flash of a blank device** — `mix burn` via the `usb_fel_loaders` U-Boot. See [usb_fel_loaders.md](./usb_fel_loaders.md) for the detailed flow.
- **Recovery from a broken U-Boot on eMMC** — same flow.
- **Dev-time env inspection on an otherwise-bricked device** — load the custom FEL U-Boot (which includes patch 3), use `fw_printenv` / `env save` to inspect or fix env.

### Boundary with usb_fel_loaders
This doc stops here. The custom FEL-loaded U-Boot (a different build than the one described in §4, configured to expose eMMC as USB Mass Storage) and the `launch.sh` flow are documented in [usb_fel_loaders.md](./usb_fel_loaders.md). Patch 3 in §4 is the only FEL-related item baked into the *eMMC-resident* U-Boot.

### Quick FEL sanity check (host-side)
```sh
# Is the badge in FEL mode and visible?
sunxi-fel version
# Expected output: AWUSBFEX soc=... scratchpad=... uboot=...
# If this works, BROM is alive and USB is fine.
```
If `sunxi-fel version` succeeds but `./launch.sh trellis` fails, suspect the custom FEL U-Boot bin or the host tooling, not the badge.

## 10. Upstream provenance

- **Lives at:** `nerves_system_trellis/uboot/` in the `nerves_system_trellis` repo.
- **Contents of that directory:**
  - `uboot_defconfig` — the defconfig file.
  - `0001-sunxi-support-uart4-console-output.patch`
  - `0002-Turn-off-DRAM-remapping-for-T113-S4.patch`
  - `0003-Support-environment-in-MMC-when-booted-in-FEL-mode.patch`
- **Built by:** Buildroot, as part of compiling `nerves_system_trellis`. The build fetches U-Boot v2025.04 upstream source, applies the three patches, uses `uboot_defconfig` as the config, produces `u-boot-sunxi-with-spl.bin`.
- **Distributed via:** the Hex package `nerves_system_trellis` — precompiled as part of the system tarball downloaded by `mix deps.get`. Normal users never rebuild U-Boot; they consume it as part of the Nerves system artifact.
- **You (as a name_badge developer) never modify it.** If the upstream doesn't need changing (and it won't for application-layer work), the `nerves_system_trellis/` directory is effectively read-only lore.

See [nerves_system_trellis.md](./nerves_system_trellis.md) for the full picture of how the system is packaged.

## 11. When you'd need to touch this

The honest answer: effectively never, unless one of the following:

- **New hardware revision.** Different DRAM chip, different pinmux, different SoC binning → requires DRAM timing retune, potentially a new patch similar to 0002, possibly a new U-Boot DT.
- **Move the console to a different UART.** Requires re-pinmuxing (patch 0001 template).
- **Change the eMMC layout** (different partition offsets/sizes). Must stay in sync between `fwup.conf`, U-Boot `CONFIG_ENV_OFFSET`, `/etc/fw_env.config`, and the extlinux configs.
- **Bump U-Boot version** (e.g. 2025.04 → 2025.10). Port the three patches; retest DRAM init on real hardware before declaring victory.
- **Debug a new boot failure mode** where the kernel never starts and you need U-Boot shell access. Enable `CONFIG_CMD_*` bits and rebuild.

Day-to-day badge work (Typst screens, IEx experiments, new GenServers, SPI peripherals in userspace) does not touch U-Boot.

### If you *do* need to rebuild U-Boot

1. Check out the `nerves_system_trellis` repo (or re-create the `uboot/` dir contents from this doc).
2. Run its Buildroot build: `make nerves_system_trellis_defconfig && make`. Buildroot fetches U-Boot v2025.04, applies the three patches, uses `uboot_defconfig`, produces `u-boot-sunxi-with-spl.bin`.
3. To test without a full system rebuild: FEL-load the new U-Boot with `sunxi-fel uboot <file>` and observe serial output on UART4 at 115200 baud.
4. To deploy: rebuild `nerves_system_trellis`, bump its version, reference it from `name_badge`'s `mix.exs`, run `mix deps.get && mix firmware && mix burn` (FEL-flash required, since you're changing U-Boot on eMMC).

## 12. Recovery: "I think U-Boot is broken"

### Symptom triage

| Symptom | Likely cause | First action |
|---|---|---|
| No serial output at all on UART4 after power | SPL didn't start, or UART pinmux is wrong | Try FEL mode — if FEL works, SPL on eMMC is corrupt. Reflash. |
| SPL prints "DRAM:" line, then silence | DRAM init or U-Boot load failure | Check DRAM clock/ODT/TPR values match hardware. Patch 0002 must be applied. |
| U-Boot prompt, but kernel doesn't load | Missing/corrupt `zImage` or `dtb` in rootfs | Check extlinux conf, check squashfs integrity. Try other A/B slot: `fw_setenv nerves_fw_active b` in U-Boot. |
| Kernel panics on mount-root | Wrong `root=` device or wrong rootfs type | Confirm extlinux conf `root=` matches actual partition. |
| Boots, but always reverts to old slot | `nerves_fw_validated` never getting set | Boot to IEx, call `Nerves.Runtime.validate_firmware()`. Check app-layer health checks. |
| Constant reboot loop | Any of the above, with OTA in progress | "Penalty box" engages after N reboots, parks device ~1 min. Keep on USB-C power, wait it out. |

### Reflash via FEL (summary)

1. Power off.
2. Hold FEL button, apply USB-C power, release button. Device is now in FEL mode.
3. From a host with `sunxi-tools`, load the custom FEL U-Boot that exposes eMMC as USB Mass Storage. On the current toolchain: `./launch.sh trellis` inside the `usb_fel_loaders` repo.
4. Device re-enumerates as a USB mass storage device. eMMC is now a raw block device on the host.
5. From `name_badge` with `MIX_TARGET=trellis`: `mix burn`. This runs `fwup` which writes U-Boot+SPL, zeros env, writes rootfs A, zeros rootfs B, creates the application partition, and sets initial env vars.

For the detailed FEL flow, troubleshooting (`usb_bulk_send() ERROR -1` etc.), and the specifics of `launch.sh`: [usb_fel_loaders.md](./usb_fel_loaders.md).

### If FEL itself doesn't work

- **USB-C cable is charge-only.** Swap for a known-good data cable. Most post-2023 USB-C cables are fine but cheap ones aren't.
- **Host can't see the FEL device.** `brew reinstall libusb` on macOS; let the badge sit in FEL mode for 5–10 s before invoking `sunxi-fel` (BROM needs a moment).
- **Genuinely dead SoC.** Rare but possible if you've fed it wrong voltages. No software fix.

---

*End of bootloader reference. For the kernel and DT it hands off to, see [device_tree_kernel.md](./device_tree_kernel.md). For the Nerves system that builds and packages this U-Boot, see [nerves_system_trellis.md](./nerves_system_trellis.md). For FEL-mode USB recovery flashing, see [usb_fel_loaders.md](./usb_fel_loaders.md). For the Elixir app that consumes `nerves_fw_active` and friends, see [elixir_application.md](./elixir_application.md).*
