# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository is a fork of [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) — the Elixir/Nerves firmware for the Protolux Trellis e-ink badge distributed at the Goatmire Elixir conference (Gothenburg, September 2025). The owner (Marko) received a badge at the conference and uses this fork as a personal playground for unrelated apps over time.

**Cleanup state (2026-04-19)**: conference-specific functionality has been stripped. Kept: core substrate (`Screen` framework, `Layout`, `Display`/Typst/Dither/EInk pipeline, `ButtonMonitor`, `ScreenManager`, `VintageNet`/`VintageNetWiFi`, `TimezoneService`, `Battery`, NervesHub link, host-mode LiveView preview + `DevReloader`), the `Weather` screen (now the home screen), and `Settings` → `WiFi` + `SystemInfo`. Removed: `NameBadge.Socket` (Goatmire websocket), `NameBadge.Gallery` + gallery screen, `NameBadge.CalendarService` + calendar screen, `Screen.NameBadge` (QR personalization), `Screen.Snake`, `Screen.Settings.{QrCode,Tutorial,SudoMode}`; deps `:qr_code`/`:slipstream`/`:icalendar` (slipstream stays transitively via `nerves_hub_link`); env vars `DEVICE_SETUP_URL`/`CALENDAR_URL`; assets `priv/sudo_mode.bin`, `priv/typst/images/tigris_logo.svg`, `priv/typst/images/icons/link*.png`.

Environment status: toolchain bootstrapped, simulator working (`MIX_TARGET=host iex -S mix`), badge previously flashed from source to `name_badge 0.3.1` over SSH (pre-cleanup). Original sibling clones (`nerves_system_trellis/`, `usb_fel_loaders/`, `goatmire/`) moved out of the workspace — they're consumed via hex or re-cloned on demand. See `docs/` for per-layer paper documentation. **Note**: `docs/elixir_application.md` predates this cleanup; sections on Socket/Gallery/Calendar/QR no longer reflect the code.

## Git Remotes

- `origin` → `git@github.com:markomitranic/name_badge.git` — this fork; push changes here.
- `upstream` → `https://github.com/protolux-electronics/name_badge.git` — original; read-only in practice.

Pull upstream updates with `git fetch upstream && git merge upstream/main` (or rebase).

Community PR worth knowing about: `protolux-electronics/name_badge#7` adds the LiveView host-mode preview (already in upstream `main`, hence in this fork).

## Documentation (`docs/`)

AI-consumable paper documentation extracted from the four upstream repos. Each file opens with its own Markdown table of contents.

- [`docs/bootloader_uboot.md`](./docs/bootloader_uboot.md)
  - Represents the second-stage bootloader (U-Boot 2025.04 + SPL) that runs after the SoC's BROM and hands control to the Linux kernel, plus the eMMC partition layout and how the device picks between the A and B firmware slots.
  - Tags: low-level, hardware, bootloader, u-boot, spl, boot-sequence, partitions, a-b-slots, firmware-selection, emmc, fel-boundary, brick-risk
- [`docs/device_tree_kernel.md`](./docs/device_tree_kernel.md)
  - Represents the Linux 6.12.32 kernel configuration, backported PWM patches, and the `sun8i-t113s-trellis.dts` device tree that describes every GPIO pin, SPI bus, and peripheral on the badge.
  - Tags: low-level, hardware, kernel, linux, device-tree, gpio, spi, uart, mmc, peripherals, drivers, wifi-driver, regulators, pinout
- [`docs/nerves_system_trellis.md`](./docs/nerves_system_trellis.md)
  - Represents the Nerves system package (Buildroot-based Linux distribution) that glues kernel + U-Boot + rootfs overlay + fwup together into the platform layer the Elixir app runs on.
  - Tags: low-level, platform, nerves-system, buildroot, linux-distribution, rootfs, erlinit, fwup, ota, toolchain, cross-compile, versioning, hex-package
- [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md)
  - Represents the FEL recovery toolkit (`launch.sh` + custom U-Boot + UMS gadget) used for first-time flashing or recovering a bricked badge over USB-C.
  - Tags: low-level, hardware, flash, brick, recovery, fel, sunxi-tools, usb, u-boot-ums, mix-burn, macos-gotchas, emergency
- [`docs/elixir_application.md`](./docs/elixir_application.md)
  - Represents the `name_badge` Elixir/Nerves application (this repo) plus a runbook of day-to-day operations, flashing, SSH/IEx commands, and recovery recipes.
  - Tags: high-level, application, elixir, nerves, screens, typst, dither, eink-rendering, vintagenet, nerveshub, config, simulator, runbook, development, daily-ops

## Hardware Quick Reference

- Board: **Trellis** (prototype name: "Wisteria"), Allwinner T113-S4 SoC (sun8i-r528 variant).
- Display: 400×300 1-bit e-ink (the FPS bottleneck, not the CPU).
- Connectivity: USB-C (power + data + SSH) and onboard Wi-Fi (Realtek, 2.4 GHz only).
- SSH hostname: `wisteria.local` (mDNS works over USB on macOS).
- Default credentials: username `nerves`, password `nerves`.

## Required Environment Variables

`mise.toml` pins `MIX_TARGET=trellis` by default. Optional overrides live in `.mise.local.toml` (git-ignored):

```toml
[env]
NERVES_WIFI_SSID = "..."
NERVES_WIFI_PASSPHRASE = "..."
# Optional:
# NH_PRODUCT_KEY = "..."
# NH_PRODUCT_SECRET = "..."
```

Wi-Fi credentials can also be set at runtime on the device via `VintageNetWiFi.quick_configure/2` (persists across reboots), so baking them into firmware is usually unnecessary.

For the **simulator**, override target per command: `MIX_TARGET=host mix deps.get`, `MIX_TARGET=host iex -S mix`.

Forgetting `MIX_TARGET=trellis` when building firmware triggers a cross-compilation error (host Mach-O vs expected ARM ELF). Recovery: `rm -rf _build deps && mix deps.get && mix firmware`.

## Common Commands

```sh
# First-time build
mix deps.get
mix firmware

# Flash over USB to a badge in FEL / mass-storage mode
mix burn

# Flash over SSH to a running badge (password: nerves)
cat _build/trellis_dev/nerves/images/name_badge.fw | ssh -s nerves@wisteria.local fwup

# Or generate a reusable upload script
MIX_TARGET=trellis mix firmware.gen.script
./upload.sh wisteria.local

# SSH into the badge (IEx prompt, password: nerves)
ssh nerves@wisteria.local
```

> [!NOTE]
> The `mix firmware` success message suggests `mix upload` — **that task does not exist in this project**. Use the pipe or `upload.sh`. Running `mix upload` fails with "The task 'upload' could not be found".

Inside IEx on the badge:

```elixir
VintageNet.info()                                   # network status
VintageNetWiFi.quick_configure("ssid", "password")  # set WiFi at runtime (persists)
NervesTime.restart_ntpd()                           # fix clock / TLS errors
Application.stop(:nerves_hub_link)                  # restart OTA link after 401
Application.ensure_all_started(:nerves_hub_link)
```

## Toolchain Prerequisites (macOS)

1. Elixir + Erlang via `mise` (run `mise install`). `mise.toml` pins Elixir 1.19.5 / Erlang 28.3.
2. Nerves bootstrap archive (one-time, user-scoped):
   ```sh
   mix local.hex --force
   mix local.rebar --force
   mix archive.install hex nerves_bootstrap --force
   ```
3. Nerves build prereqs — all three are required:
   ```sh
   brew install xz fwup squashfs
   ```
4. `sunxi-tools` for FEL / USB recovery flashing only — prefer the HEAD build:
   ```sh
   brew install --build-from-source --head lukad/sunxi-tools-tap/sunxi-tools
   ```
5. `sshpass` (optional, only if automating flash/ssh without typing passwords):
   ```sh
   brew install hudochenkov/sshpass/sshpass
   ```

Rust is no longer required (typst NIF ships pre-compiled).

## FEL Recovery Flash Flow

For first-time flashing or brick recovery. Full procedure in [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md).

```sh
# 1. Power off badge → hold FEL button → power on → release.
# 2. Clone usb_fel_loaders (or run from a fresh copy):
git clone https://github.com/gworkman/usb_fel_loaders && cd usb_fel_loaders
./launch.sh trellis                                # auto-downloads trellis.bin
# 3. From this repo:
MIX_TARGET=trellis mix burn
```

If `usb_bulk_send() ERROR -1` appears: let the badge sit in FEL for a few seconds, try a known-good USB-C **data** cable, or `brew reinstall libusb`.

## Gotchas Worth Remembering

- **Screen templates are Typst, not EEx.** Use Elixir string interpolation `#{var}`; `<%= %>` will crash the renderer. A leading `#` on the first Typst line also crashes it.
- **Status bar is built in `lib/name_badge/layout.ex` `icons_markup/0`.** It's a Typst `#place(top + right, …)` with a `stack(dir: ltr, …)` of `image("images/icons/*.png")` calls. To add an icon: drop a ~16 pt PNG into `priv/typst/images/icons/` and add one `image(...)` line in the stack.
- **`mix upload` is NOT a task in this project** — use the SSH pipe or `upload.sh`.
- **Clock drift after boot** causes TLS "Certificate Expired" errors and NervesCloud 401s. They self-heal via NTP; force with `NervesTime.restart_ntpd()`.
- **After reflash**, run `ssh-keygen -R wisteria.local` to clear the stale host key.
- **Post-fwup reboot takes 2–3 minutes**, not 30–60 s. Ping comes back first, then SSH once BEAM is up.
- **OTA penalty box**: too many reboots during an update parks the device for ~1 minute. Keep on USB power and wait.
- **Keep the badge on USB-C power during OTA updates** — they can take ~10 min.
- **WiFi chip is 2.4 GHz only** (Realtek RTL8188FU, visible in dmesg). Dual-band SSIDs fine; 5 GHz-only SSIDs won't connect.
- **`VintageNetWiFi.quick_configure(ssid, psk)` persists across reboots** — usually faster than rebuilding firmware to change `NERVES_WIFI_SSID`/`NERVES_WIFI_PASSPHRASE`.
- **Check connection state, not just "associated"**: `VintageNet.get(["interface","wlan0","connection"])` → `:disconnected | :lan | :internet`. Wait for `:internet` before expecting NTP / NervesCloud / weather sync.
- **Switching targets corrupts `_build`**: if you build for `host` then `trellis` (or vice versa), native NIFs end up wrong-arch. Symptom: `scrub-otp-release.sh: ERROR: Unexpected executable format`. Fix: `mix deps.clean dither typst && MIX_TARGET=trellis mix deps.get`.

## When Answering Hardware / Firmware Questions

Order of authority (most fresh → least):

1. **This repository** — code, `mix.exs`, `config/`, `lib/`, `priv/typst/`. Ground truth for the app layer.
2. **`docs/`** — per-layer paper documentation. Captures everything that used to live in the sibling clones. Runbook lives in `elixir_application.md`.
3. **Upstream repos on GitHub** — re-clone temporarily if you need source-level access beyond what `docs/` captures:
   - `protolux-electronics/name_badge` (upstream of this fork)
   - `protolux-electronics/nerves_system_trellis` (consumed as hex package)
   - `gworkman/usb_fel_loaders` (FEL recovery toolkit)
4. **General Nerves/Elixir knowledge** — fall back when the above don't cover the case.
