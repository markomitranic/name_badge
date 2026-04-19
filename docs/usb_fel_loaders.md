# usb_fel_loaders — FEL Recovery Toolkit for the Trellis Badge

Reference doc for the `usb_fel_loaders` toolkit: Allwinner FEL mode, the custom U-Boot + UMS image, `launch.sh`, and the full brick-recovery procedure. This doc exists because the local `./usb_fel_loaders/` clone will be deleted once `name_badge` is forked — everything you need to flash or recover a badge without the source tree is captured here.

Cross-references: [bootloader_uboot.md](./bootloader_uboot.md), [device_tree_kernel.md](./device_tree_kernel.md), [nerves_system_trellis.md](./nerves_system_trellis.md), [elixir_application.md](./elixir_application.md).

---

## 1. Table of Contents

1. [Table of Contents](#1-table-of-contents)
2. [What is FEL mode](#2-what-is-fel-mode)
3. [When to use this toolkit](#3-when-to-use-this-toolkit)
4. [Overview of the project](#4-overview-of-the-project)
5. [Supported boards](#5-supported-boards)
6. [What `trellis.bin` actually contains](#6-what-trellisbin-actually-contains)
7. [Directory structure of the upstream repo](#7-directory-structure-of-the-upstream-repo)
8. [Prerequisites](#8-prerequisites)
9. [Full recovery procedure](#9-full-recovery-procedure)
10. [How `launch.sh` works internally](#10-how-launchsh-works-internally)
11. [macOS gotcha — the "unrecognized disk" prompt](#11-macos-gotcha--the-unrecognized-disk-prompt)
12. [How this integrates with `mix burn`](#12-how-this-integrates-with-mix-burn)
13. [Version tracking / release mechanism](#13-version-tracking--release-mechanism)
14. [Custom U-Boot config vs runtime U-Boot](#14-custom-u-boot-config-vs-runtime-u-boot)
15. [Two U-Boot patches in the FEL image](#15-two-u-boot-patches-in-the-fel-image)
16. [Rebuilding from source](#16-rebuilding-from-source)
17. [Release process](#17-release-process)
18. [Common errors and fixes](#18-common-errors-and-fixes)
19. [Provenance](#19-provenance)

---

## 2. What is FEL mode

**FEL** is Allwinner's USB recovery protocol, baked into the SoC's mask-ROM (BROM). When the BROM finds no bootable media — or when the FEL button is held during boot — the CPU enters FEL and listens on USB0 (the OTG / peripheral-mode port) for commands from a host.

Key properties:

- Fully hardware-based. No software on the device is required — the BROM is ROM.
- Cannot be bricked from software. Unless the silicon itself fails, FEL is always reachable.
- Speaks a proprietary USB protocol. The host side is spoken by `sunxi-fel` (part of `sunxi-tools`).
- Lets the host upload code to SRAM, start the CPU at any address, read/write memory, and (via DRAM init blobs) load code into DRAM.

On the Trellis, the **FEL button** is a small tactile button on the PCB. Holding it during power-on forces FEL mode even when eMMC has a valid boot image.

See also: [bootloader_uboot.md](./bootloader_uboot.md) for how U-Boot proper (the runtime bootloader) differs from what FEL uploads.

---

## 3. When to use this toolkit

**USE FEL for:**

- First-time provisioning of a blank / mis-flashed board.
- Recovery when the device will not boot (both A/B slots corrupted, or U-Boot itself is broken).
- Switching between totally different firmware projects on the same hardware.

**DO NOT use FEL for day-to-day iteration.** Once the badge boots Nerves and answers on `wisteria.local`, flash via the SSH pipe:

```sh
cat _build/trellis_dev/nerves/images/name_badge.fw | ssh -s nerves@wisteria.local fwup
```

or the generated helper:

```sh
MIX_TARGET=trellis mix firmware.gen.script
./upload.sh wisteria.local
```

FEL is the nuclear option — it erases eMMC and rewrites everything.

---

## 4. Overview of the project

`usb_fel_loaders` is a small **Buildroot-based** project that produces a single binary per supported board: a concatenation of Allwinner SPL + U-Boot proper, configured to come up as a **USB Mass Storage (UMS) gadget** exposing the onboard eMMC to the host.

Source: `https://github.com/gworkman/usb_fel_loaders`

Why this exists: the generic upstream U-Boot for sun8i doesn't default to UMS. This project ships a pre-patched, pre-configured U-Boot whose `bootcmd` is literally:

```
mmc dev 0 && ums 0 mmc 0:0 && reset
```

Upload it via FEL → board appears as a USB disk → `fwup` (via `mix burn`) writes the firmware → disconnect → `reset` reboots the board into the new firmware. No further tooling needed on the device.

---

## 5. Supported boards

| Board key | Target hardware | SoC | Arch |
|-----------|-----------------|-----|------|
| `trellis` | Protolux Trellis e-ink badge | Allwinner T113-S4 (sun8i-r528) | ARMv7 (Cortex-A7 x2) |
| `pine64`  | Pine64+ SBC                  | Allwinner A64 (sun50i)         | ARMv8 (Cortex-A53)   |

Each board has its own defconfig and U-Boot config under `builder/boards/<board>/`. The rest of this doc focuses on `trellis`; `pine64` is listed only for completeness.

---

## 6. What `trellis.bin` actually contains

- **File**: `u-boot-sunxi-with-spl.bin` renamed to `trellis.bin`.
- **Size**: ~568 KB.
- **Contents**: Allwinner-format SPL (Secondary Program Loader) concatenated with U-Boot proper.
- **Built from**: Buildroot 2025.02.1 + U-Boot 2025.04 + the two Trellis U-Boot patches (see §15).

### U-Boot defconfig highlights

```
CONFIG_ARM=y
CONFIG_ARCH_SUNXI=y
CONFIG_MACH_SUN8I_R528=y
CONFIG_SPL=y
CONFIG_BOOTCOMMAND="mmc dev 0 && ums 0 mmc 0:0 && reset"
CONFIG_CMD_USB_MASS_STORAGE=y
CONFIG_USB_MUSB_GADGET=y
CONFIG_USB_GADGET_MANUFACTURER="Trellis USB FEL Loader"
CONFIG_CONS_INDEX=5
```

### Runtime behavior

1. SPL is uploaded to SRAM, initializes DRAM, loads U-Boot proper into DRAM.
2. U-Boot starts, runs `bootcmd`:
   - `mmc dev 0` — select eMMC as the current MMC device.
   - `ums 0 mmc 0:0` — expose eMMC via USB Mass Storage gadget on USB0. Blocks while the host has the disk open.
   - `reset` — once the host disconnects (i.e. `mix burn` / `fwup` finishes writing), reboot.
3. The board reboots into whatever was just flashed to eMMC.

No environment is read from eMMC. No filesystem logic. This U-Boot is **single-purpose**.

---

## 7. Directory structure of the upstream repo

```
usb_fel_loaders/
├── .circleci/config.yml
├── CHANGELOG.md                # v0.1.0, v0.2.0 entries
├── Makefile                    # `make all` → release/trellis.bin + release/pine64.bin
├── README.md
├── VERSION                     # current: v0.2.0
├── launch.sh                   # main entry point (run this)
├── trellis.bin                 # prebuilt, checked in for convenience
└── builder/
    ├── Config.in
    ├── external.desc           # Buildroot external tree descriptor ("CUSTOM")
    ├── external.mk
    ├── build.sh                # invokes create-build.sh then `make`
    ├── create-build.sh         # initializes Buildroot 2025.02.1 build dir
    ├── boards/
    │   ├── pine64/uboot.config
    │   └── trellis/
    │       ├── sun8i-t113s-trellis.dts
    │       ├── uboot_defconfig
    │       └── uboot/
    │           ├── 0001-sunxi-support-uart4-console-output.patch
    │           └── 0002-Turn-off-DRAM-remapping-for-T113-S4.patch
    ├── configs/
    │   ├── pine64_defconfig
    │   └── trellis_defconfig
    └── scripts/
        ├── buildroot-state.sh
        ├── clone_or_dnload.sh
        └── download-buildroot.sh
```

Not tracked (generated):

- `builder/o/` — Buildroot output directory (huge).
- `builder/dl/` — Buildroot download cache.
- `release/` — final `.bin` outputs.

---

## 8. Prerequisites

### 8.1 sunxi-tools ≥ 1.4.2 (required)

On macOS, prefer a HEAD build — tagged releases are stale and miss fixes relevant to recent Allwinner SoCs.

**Option A — Homebrew tap (recommended):**

```sh
brew install --build-from-source --head lukad/sunxi-tools-tap/sunxi-tools
```

**Option B — build from source:**

```sh
brew install libusb dtc
git clone https://github.com/linux-sunxi/sunxi-tools
cd sunxi-tools
CFLAGS="-I$(brew --prefix dtc)/include" LDFLAGS="-L$(brew --prefix dtc)/lib" make
sudo cp sunxi-fel /usr/local/bin/
```

Verify:

```sh
sunxi-fel --version
which sunxi-fel
```

### 8.2 curl or wget (required by `launch.sh`)

Either is fine. `launch.sh` tries `curl -L --fail` first, then `wget` as a fallback.

### 8.3 USB-C **data** cable (required)

Many USB-C cables are charge-only. They look identical. A charge-only cable is the single most common cause of `usb_bulk_send() ERROR -1`. Keep a known-good data cable earmarked for this.

### 8.4 No Rust, Elixir, or Nerves toolchain needed

`usb_fel_loaders` has zero dependencies on the Elixir / Nerves side. You can use it with any firmware `.fw` image that `fwup` can write.

---

## 9. Full recovery procedure

Checklist form. Follow top to bottom.

### Step 1 — Enter FEL mode

1. Unplug USB-C from the badge. There is no hard power switch; the battery keeps it running briefly, so wait ~5 s.
2. Hold the **FEL button** (small tactile button on the PCB) down.
3. While holding FEL, plug USB-C back in.
4. Wait ~1 s. Release the FEL button.

The BROM is now listening on USB0. Verify from the host:

```sh
sunxi-fel version
```

Expected output (example):

```
AWUSBFEX soc=00185100(R528) 00000001 ver=0001 44 08 scratchpad=00027e00 00000000 00000000
```

If nothing shows up, the board is not in FEL. Power-cycle and try again.

### Step 2 — Get `launch.sh` + `trellis.bin`

Option A — clone (easiest):

```sh
git clone https://github.com/gworkman/usb_fel_loaders
cd usb_fel_loaders
chmod +x launch.sh
```

Option B — minimal (just two files):

```sh
mkdir fel && cd fel
curl -LO https://raw.githubusercontent.com/gworkman/usb_fel_loaders/main/launch.sh
curl -LO https://github.com/gworkman/usb_fel_loaders/releases/latest/download/trellis.bin
chmod +x launch.sh
```

### Step 3 — Upload U-Boot via FEL

```sh
./launch.sh trellis
```

The script:

1. Confirms `sunxi-fel` is present.
2. Downloads `trellis.bin` from GitHub Releases if missing locally.
3. Prints a destructive-op warning.
4. Polls for FEL presence with a spinner.
5. Runs `sunxi-fel uboot trellis.bin`.
6. Sleeps 5 s for the UMS gadget to enumerate.
7. Prints "DONE!"

### Step 4 — Dismiss the macOS disk dialog

macOS will pop **"The disk you inserted was not readable by this computer"**.

**Click "Ignore".** Not Initialize. Not Eject. See §11 for why.

### Step 5 — Flash with `mix burn`

From the `name_badge` source tree:

```sh
cd ~/Sites/eink_spotify/name_badge
MIX_TARGET=trellis mix firmware    # only if not already built
MIX_TARGET=trellis mix burn
```

`mix burn` scans for unmounted removable block devices, matches the Trellis by size/vendor string, prompts for confirmation, and invokes `fwup` under the hood to write the `.fw`.

Device paths:

- **Linux**: `/dev/sdX` (or `/dev/mmcblkX`).
- **macOS**: `/dev/disk<N>` (and `/dev/rdisk<N>` — the raw counterpart, used for speed).

### Step 6 — Wait for reboot

When `mix burn` finishes, it unmounts / disconnects the UMS gadget. U-Boot's `bootcmd` proceeds from `ums ...` to `reset`. The board reboots into the freshly flashed firmware automatically.

First post-flash boot: **2–3 minutes** before SSH answers on `wisteria.local`. The BEAM takes a while to start; ping comes back first (USB-ethernet re-enumerates quickly), then SSH.

Clear any stale host key before SSHing:

```sh
ssh-keygen -R wisteria.local
ssh nerves@wisteria.local    # password: nerves
```

---

## 10. How `launch.sh` works internally

Script: ~102 lines. Flow:

1. **Read VERSION file.** From the script's own directory. If missing, defaults to `latest`.
2. **Validate args.** Exactly one arg: `trellis` or `pine64`. Anything else → usage error.
3. **Check `sunxi-fel` in PATH.** Fatal if missing (prints install hint).
4. **Create `release/` dir** if it doesn't exist.
5. **Auto-download `<board>.bin`** if `release/<board>.bin` is missing:
   - URL template: `https://github.com/gworkman/usb_fel_loaders/releases/download/<VERSION>/<board>.bin`
   - If `VERSION=latest`, uses `/releases/latest/download/<board>.bin`.
   - Tries `curl -L --fail -o release/<board>.bin <URL>` first.
   - Falls back to `wget -O release/<board>.bin <URL>`.
6. **Print destructive warning:**
   ```
   [!!] THIS WILL ERASE THE DEVICE'S CURRENT FIRMWARE UPON CONNECTING [!!]
   ```
7. **Prompt user** to put the board in FEL and connect.
8. **Poll for FEL presence.** Runs `sunxi-fel version > /dev/null 2>&1` every 0.5 s with a spinner animation. Uses `tput civis` / `tput cnorm` to hide/show the cursor.
9. **Print board FEL version** (full `sunxi-fel version` output).
10. **Upload U-Boot:**
    ```sh
    sunxi-fel uboot release/<board>.bin
    ```
    This one command handles SPL upload, DRAM init, U-Boot load, and jump.
11. **Sleep 5 s.** Gives the host OS time to enumerate the new UMS device.
12. **Print "DONE!"** and tell the user the board is now a USB storage device.

**Only one `sunxi-fel` subcommand is used for real work: `sunxi-fel uboot`.** The `sunxi-fel version` calls in the polling loop are purely for presence detection.

---

## 11. macOS gotcha — the "unrecognized disk" prompt

Within ~5 s of `sunxi-fel uboot trellis.bin` completing, macOS pops:

> "The disk you inserted was not readable by this computer."
>
> [ Initialize... ] [ Ignore ] [ Eject ]

**Always click "Ignore".**

- **Initialize** → launches Disk Utility. It will attempt to partition the device. This corrupts the FEL-loader state and usually wedges the badge until power-cycle.
- **Eject** → tells macOS to unmount, which causes U-Boot's `ums` command to exit and `reset` to fire — the board reboots before `mix burn` gets a chance to write anything.
- **Escape / dismiss** — behavior varies by macOS version. Don't rely on it.
- **Ignore** → macOS stops trying to mount the device but leaves it visible to lower-level tools (`diskutil list`, `fwup`). This is what `mix burn` needs.

After clicking Ignore, you can verify with:

```sh
diskutil list
```

You should see a disk of ~eMMC size (e.g. 8 GB) with no recognizable filesystem.

---

## 12. How this integrates with `mix burn`

`mix burn` is the Nerves task that writes a firmware image to attached media. It delegates to **`fwup`** (the same tool used on the device for A/B upgrades).

Under the hood:

1. `fwup --framing` scans `/dev/disk*` (macOS) or `/dev/sd*` (Linux) for unmounted removable devices.
2. Matches by size and vendor string (`"Trellis USB FEL Loader"` from the U-Boot gadget config, see §6).
3. Prompts for confirmation: `Use /dev/rdisk4? [Yn]`
4. Streams the `.fw` content to the raw device, applying the fwup.conf recipe (partition table, A/B slots, rootfs squashfs, etc.).
5. Flushes; `fwup` exits.
6. The UMS gadget sees the host close the endpoint → `ums` command in U-Boot exits → `reset` in `bootcmd` fires → board reboots.

If `mix burn` can't find the device:

- Check `diskutil list` (macOS) or `lsblk` (Linux) to confirm the UMS device is visible.
- On macOS: did you click Ignore and not Initialize/Eject? (§11)
- If no device is shown at all, the FEL-mode U-Boot upload failed or already timed out. Re-run §9 from step 1.

Related file: `./name_badge/config/target.exs` references `fwup.conf`; `name_badge/fwup.conf` defines the partition layout. See [nerves_system_trellis.md](./nerves_system_trellis.md) for the deeper chain.

---

## 13. Version tracking / release mechanism

### VERSION file

Plain text file at repo root. Contains a single line, e.g.:

```
v0.2.0
```

Consumed by `launch.sh` to decide the download URL. If you want the newest release regardless of which snapshot of the repo you cloned, change it to:

```
latest
```

### GitHub Releases

Artifacts are uploaded to `https://github.com/gworkman/usb_fel_loaders/releases`:

- `trellis.bin`
- `pine64.bin`

`launch.sh` downloads them from `/releases/download/<VERSION>/<board>.bin`.

### Tagged releases so far

| Tag    | Date       | Notes |
|--------|------------|-------|
| v0.1.0 | 2025-04-14 | Initial public release. Earlier workflow was "download the release zip, do not clone". |
| v0.2.0 | 2026-03-01 | Refactored Makefile. `launch.sh` gained auto-download. Repo became clone-friendly. Fixed "partition not found" and "device never reboots" regressions (Sep 2025 commits). |

### CI

CircleCI (`.circleci/config.yml`) runs `make all` inside `cimg/base:stable` with `cpio rsync bc` added. Builds both `trellis.bin` and `pine64.bin` on every commit. **CI does not upload release artifacts** — that's a manual step (see §17).

---

## 14. Custom U-Boot config vs runtime U-Boot

Two distinct U-Boots live in the Trellis ecosystem. Do not confuse them.

| Aspect | FEL-loader U-Boot (this repo) | Runtime U-Boot (nerves_system_trellis) |
|--------|-------------------------------|-----------------------------------------|
| Where it lives | Uploaded to DRAM via FEL, never touches eMMC | SPL + U-Boot in eMMC boot area |
| How invoked | Host runs `sunxi-fel uboot trellis.bin` | BROM loads SPL from eMMC on normal boot |
| `bootcmd` | `mmc dev 0 && ums 0 mmc 0:0 && reset` | Loads kernel + DTB + rootfs from A/B slot |
| Reads env from MMC? | No | Yes (patch #3 in nerves_system_trellis) |
| USB Mass Storage gadget | Yes — the whole point | Not used |
| Purpose | One-shot recovery | Normal boot chain |
| Patches applied | 2 (uart4 + DRAM remap) | 3 (uart4 + DRAM remap + env-in-MMC) |

Both derive from upstream U-Boot 2025.04 with Allwinner sun8i-r528 support. The FEL-loader variant is deliberately minimal and single-purpose.

See [bootloader_uboot.md](./bootloader_uboot.md) for the runtime U-Boot details.

---

## 15. Two U-Boot patches in the FEL image

Located under `builder/boards/trellis/uboot/`:

### `0001-sunxi-support-uart4-console-output.patch`

Adds GPIO pinmux configuration so U-Boot's serial console goes out UART4 (pins PD7/PD8). Without this, you get no boot log on the Trellis's debug header.

### `0002-Turn-off-DRAM-remapping-for-T113-S4.patch`

The T113-S4 die has DRAM fuses that upstream U-Boot misreads, causing it to remap DRAM regions and crash. Patch disables the remap logic for this specific SoC variant.

### Relationship to `nerves_system_trellis` patches

`nerves_system_trellis` applies **three** patches to its runtime U-Boot:

1. uart4 console (same as patch 1 here).
2. T113-S4 DRAM remap (same as patch 2 here).
3. Persist env to MMC (NOT in the FEL image — this U-Boot doesn't read or write env, it goes straight to `ums`).

Patches 1 and 2 are bit-identical across both projects. When upstream U-Boot eventually lands these fixes, both projects can drop them.

---

## 16. Rebuilding from source

**Linux-only.** Buildroot does not build on macOS (case-insensitive filesystem + missing GNU tooling). If you're on macOS and need to modify the FEL loader, use a Linux VM, container, or CI.

### One-time setup

```sh
git clone https://github.com/gworkman/usb_fel_loaders
cd usb_fel_loaders
sudo apt install build-essential git cpio rsync bc file wget unzip
# (or equivalents on Fedora/Arch)
```

### Build

```sh
make all
```

This runs `builder/build.sh`, which:

1. Calls `builder/scripts/download-buildroot.sh` → fetches Buildroot 2025.02.1 tarball into `builder/dl/` (once).
2. Calls `builder/create-build.sh` → unpacks Buildroot into `builder/o/<board>/`, applies the external tree descriptor.
3. Runs `make O=<...> trellis_defconfig` then `make O=<...>` inside Buildroot.
4. Copies `builder/o/<board>/images/u-boot-sunxi-with-spl.bin` → `release/<board>.bin`.

First build: **20–40 minutes** (downloads U-Boot source, cross-compiler, builds everything). Subsequent builds: seconds, unless you `git clean -fdx`.

### Per-board build

```sh
make trellis    # only trellis.bin
make pine64     # only pine64.bin
```

### Clean

```sh
git clean -fdx    # nukes builder/o, builder/dl, release
```

---

## 17. Release process

Maintainer workflow (`gworkman` does this by hand):

```sh
# 1. Edit VERSION file: e.g. v0.2.1
# 2. Update CHANGELOG.md with the new section.

git commit -am "v0.2.1 release"
git tag -a v0.2.1 -m "v0.2.1 release"

# 3. Clean build to guarantee artifacts match the tag.
git clean -fdx
make all

# 4. Push tag + main.
git push --tags
git push

# 5. MANUALLY upload release/trellis.bin and release/pine64.bin to
#    the new GitHub Release at
#    https://github.com/gworkman/usb_fel_loaders/releases/new
```

CircleCI will rebuild on the push but does not push artifacts. That last step is the critical one — without the manual upload, `launch.sh` can't auto-download for that version.

---

## 18. Common errors and fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `sunxi-fel: command not found` | Not installed. | `brew install --build-from-source --head lukad/sunxi-tools-tap/sunxi-tools` (macOS). |
| `usb_bulk_send() ERROR -1: Input/output error` | Flaky USB. | (1) Let the board sit in FEL for 3–5 s before running launch.sh. (2) Try a known-good USB-C **data** cable. (3) `brew reinstall libusb`. |
| `launch.sh` spinner forever | FEL mode not actually entered. | Power-cycle. Hold FEL from fully powered-off state. Verify with `sunxi-fel version` manually before running launch.sh. |
| "Partition not found" from U-Boot | Pre-v0.2.0 bug on already-flashed boards. | Upgrade: edit VERSION to `latest` or `v0.2.0`, re-run launch.sh. |
| `mix burn` doesn't see the device (macOS) | "Unrecognized disk" dialog was dismissed with Initialize or Eject. | Re-run §9 from step 1. On the dialog, click **Ignore**. |
| `mix burn` doesn't see the device (Linux) | auto-mounter may have grabbed the disk. | `sudo umount /dev/sdX*`. |
| Board never reboots after flashing | Pre-Sep 2025 FEL loader. | Upgrade to v0.2.0+. |
| "Could not find 'xz'" during `mix deps.get` | Missing brew package (Nerves-side, not FEL). | `brew install xz fwup squashfs`. |
| Permission denied on `/dev/sdX` (Linux) | `fwup` needs root or udev rule. | `sudo -E mix burn` or set up a udev rule. |
| Board flashes OK but doesn't boot | Firmware itself is broken; flash succeeded. | See [nerves_system_trellis.md](./nerves_system_trellis.md) and [elixir_application.md](./elixir_application.md). Re-enter FEL, flash a known-good `.fw`. |
| `launch.sh` auto-download fails | Behind a proxy, or network down, or tag typo in VERSION. | Download `trellis.bin` manually into `release/trellis.bin`. |

---

## 19. Provenance

- **GitHub repo**: `https://github.com/gworkman/usb_fel_loaders`
- **Owner**: Gus Workman (`gworkman` on GitHub). Lead maintainer of the Trellis firmware stack.
- **Org ownership**: Stayed at `gworkman/...`. A rumored move to `protolux-electronics/...` never happened. If you see old notes saying "the repo will move to `protolux-electronics`", ignore them.
- **License**: Check the repo — typically MIT / GPLv2 for projects of this shape.

### Outdated claims from older notes (DISCORD.md, older CLAUDE.md)

- **"Do not clone `usb_fel_loaders`; download the release zip only."** Outdated. That was accurate for v0.1.0, before `launch.sh` existed. From v0.2.0 onward, cloning is the intended flow; `launch.sh` handles artifact fetching.
- **"The repo has moved to protolux-electronics."** Never happened.
- **"trellis.bin must be downloaded and placed manually."** Only true as a fallback. `launch.sh` auto-downloads by default.

Trust this doc and the current upstream `README.md` over any older notes. When in doubt, check `git log` on the upstream repo.
