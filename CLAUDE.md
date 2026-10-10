# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What This Is

Firmware for a single-purpose Spotify cover display, built on the Protolux Trellis e-ink badge. It boots straight into one screen that shows an album from the owner's (Marko's) Spotify saved library in a cassette-spine layout, rotates every 5 minutes, and skips on button A. Button B does nothing. There are no menus, settings, splash, status bar or host simulator, by design.

**Priorities, in order: stability, battery life, simplicity.** Before adding anything, ask whether a 1-click utility device needs it. Removed features live in git history (multi-screen `Screen`/`ScreenManager` framework, `Layout` status bar, Settings → WiFi wizard + System Info, `TimezoneService`/tzdata, NervesHub link, `GrayTune` LUT calibration harness, LiveView simulator + mocks, power measurement scripts).

The repo started as a fork of [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) (Goatmire 2025 conference badge) and has diverged completely. Upstream is no longer a source of changes. Module names still carry the `NameBadge` prefix and the release is still `name_badge`/product `goatmire`; renaming isn't worth the churn (the product name feeds firmware metadata).

## Architecture

Everything is device-only: the app does not build for `MIX_TARGET=host`.

Supervision tree (`NameBadge.Application`, one_for_one):

| Child | Role |
|---|---|
| `NameBadge.PowerMonitor` | Re-powers WiFi within 10 s of USB power appearing |
| `EInk` | Panel driver singleton (dep), configured via `config :eink` |
| `NameBadge.Display` | Serializes draws; PNG or Typst template → `EInk` |
| `NameBadge.TaskSupervisor` | Runs refill bursts |
| `NameBadge.Spotify.Tokens` | OAuth refresh-token → access-token exchange; persists rotated refresh tokens |
| `NameBadge.Spotify.Library` | Random saved album: cached library size (24 h) + one offset query per album |
| `NameBadge.Spotify.ArtCache` | Disk queue of pre-dithered covers; triggers refill bursts; switches WiFi off |
| `NameBadge.Spotify.Screen` | The screen: takes a cover, composes the spine with Typst, draws it |
| `NameBadge.Button` | BTN_1 falling edge → `:button_pressed` to the screen |

Plain modules: `Battery` (stateless ADC reads + discharge curve), `Network` (WiFi on/off/await), `Wifi` (VintageNet power manager driving `WIFI_EN`), `Spotify.{HTTP, Art, Album}`, `Diagnostics` (monitoring, off).

**Flow**: `Screen` sends itself `:rotate` at boot and every 5 min (30 s retry when the cache is empty, holding the last cover). Each rotate calls `ArtCache.take/0`, which pops a cover, starts a refill task when fewer than 3 remain (unless the battery is low or a refill failed in the last 3 min), and powers WiFi off when no refill is running. A refill turns WiFi on, waits for `:internet`, fetches covers until the queue is back to 10 (`Library.random_album` → `Art.fetch`: download, resize to 300×300, contrast stretch, Stucki dither to 2 bits), then turns WiFi off. Button presses cancel the timer, rotate immediately, and drop presses that queued up during the ~1.3 s draw.

**Boot**: no splash. The panel holds its last image unpowered, so the previous cover stays up until the first new one is drawn.

**Rendering**: 4-level grayscale (`mode: :grayscale, dither: false`; art is pre-dithered to exactly {0, 85, 170, 255}). The calibrated UC8276 waveform lives in Marko's `eink` fork, branch `grayscale-on-dp`; swap back to hex once upstream ships a real grayscale LUT. Spine text is Poppins with per-glyph fallback to Noto Sans JP; only the weights in use ship in `priv/typst/fonts`. `anti_ghost: true` in `@draw_opts` adds a white flush before each draw; it's off because the double refresh was more annoying than the ghosting.

**Runtime files** (`/data/`): `spotify_tokens.json` (rotated refresh token, falls back to the compiled-in one), `spotify_library.json` (library size + fetch time), `spotify_art/` (`<id>.png` + `<id>.json` pairs).

## Power Management

The WiFi chip is the dominant drain. It is hard-powered-off at the `WIFI_EN` GPIO when VintageNet deconfigures `wlan0`. The policy is deliberately dumb:

- **On battery, WiFi is off except during refill bursts** (~20 s each, roughly every 35-50 min of rotation). VintageNet powers it up at boot from the persisted config; the first `take` powers it straight down.
- **Low battery (< 3.65 V, ~35%) skips refills** (`Battery.low?/0`). The chip's power-on surge browned the board out mid-refill at 3.56 V (survived 3.57 V); that also explains the July 2026 hard reset during a battery drain test.
- **On USB power WiFi never turns off**: `Network.wifi_off/0` refuses while `Battery.charging?()` (> 4.5 V; the ADC reads the input rail), and `PowerMonitor` brings it back after plug-in. USB never reads low.
- **`Network.wifi_on/0` / `wifi_off/0` never touch the persisted config**, so a reboot always comes back with WiFi configured. Power-on hold time is 10 s.
- **`Battery` is stateless**: one sysfs read per call, no polling process.
- **Discharge curve** (`Battery.percentage_at/1`): from two full WiFi-on drains, 6-7 h from full to dead at ~3.35 V; 3.55 V ≈ 10% (~40 min with WiFi on). Nothing on the badge displays it.
- **Red status LED silenced at boot** (~0.5 mA). Re-enable: `File.write!("/sys/class/leds/red:status/trigger", "heartbeat")`.

## Monitoring (off by default)

`NameBadge.Diagnostics` holds three recorders, each enabled by uncommenting one line in `NameBadge.Application`:

- `Diagnostics.attach_disk_logger()`: warning+ logs and crash reports to `/data/debug.log` (2×512 KB). RingLogger is RAM-only and loses everything on reboot.
- `Diagnostics.log_boot()`: a `ts,boot,voltage,wifi` line per boot in `/data/power.log`. A boot with no graceful `/data/shutdown.txt` update means a hard reset (watchdog, brownout, power cut).
- `NameBadge.Diagnostics` child: minute health samples (load, memory, scheduler queues, key process mailboxes, voltage, wifi state) to `/data/health.jsonl` (2×2 MB) plus the last two boots' `dmesg`. `Diagnostics.measure/2` already wraps draws, cover download/dither/compose and refills; while the recorder is off those calls cost a dropped cast.

Re-derive the discharge curve from `health.jsonl` voltage samples if the load profile changes.

## Commands

Scripts are the supported workflow. They go through `mise exec` on purpose (see Gotchas).

```sh
./scripts/build.sh && ./scripts/push.sh   # build + OTA flash to wisteria.local (password: nerves)
./scripts/ssh.sh                          # IEx on the badge
./scripts/burn.sh                         # USB-FEL first flash / brick recovery
./scripts/clean.sh                        # wipe _build + deps
SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=... elixir scripts/spotify_auth.exs  # one-time OAuth
```

Compile check without building firmware: `mise exec -- env MIX_TARGET=trellis mix compile`.

On the badge:

```elixir
NameBadge.Battery.voltage()                         # e.g. 3.82 (> 4.5 on USB)
NameBadge.Battery.percentage()                      # 0-100 along the measured curve
NameBadge.Network.wifi_present?()                   # chip physically powered?
send(NameBadge.Spotify.Screen, :button_pressed)     # same as button A
VintageNetWiFi.quick_configure("ssid", "password")  # set WiFi (persists)
VintageNet.get(["interface", "wlan0", "connection"])  # :disconnected | :lan | :internet
NervesTime.restart_ntpd()                           # fix clock / TLS errors
RingLogger.grep(~r/Spotify|terminating/)            # recent logs (RAM only)
```

## Configuration

`mise.toml` pins `MIX_TARGET=trellis` and the toolchain. Secrets live in `.mise.local.toml` (git-ignored):

```toml
[env]
# Required, compiled into the firmware. Missing → "Spotify not configured" page.
SPOTIFY_CLIENT_ID = "..."
SPOTIFY_CLIENT_SECRET = "..."
SPOTIFY_REFRESH_TOKEN = "..."
# Optional first-boot WiFi baked into a burn (config/provisioning.conf):
# NERVES_WIFI_SSID = "..."
# NERVES_WIFI_PASSPHRASE = "..."
```

Lost the local file? The Spotify values can be read back off a running badge: `Application.get_env(:name_badge, :spotify)`. Before flashing, confirm they made it into the release: `_build/trellis_dev/rel/name_badge/releases/0.3.1/sys.config`.

WiFi is normally set at runtime with `VintageNetWiFi.quick_configure/2` over SSH (the USB cable works without WiFi). There is no on-device WiFi setup.

## Toolchain Prerequisites (macOS)

1. `mise install` (Elixir 1.19.5 / Erlang 28.3).
2. Once per machine:
   ```sh
   mix local.hex --force
   mix local.rebar --force
   mix archive.install hex nerves_bootstrap --force
   ```
3. All required (`pkg-config` for `vintage_net_wifi`'s native build, `coreutils` for `gstat` in `mix firmware`):
   ```sh
   brew install xz fwup squashfs pkg-config coreutils
   ```
4. FEL recovery only: `brew install --build-from-source --head lukad/sunxi-tools-tap/sunxi-tools`.

## FEL Recovery

For first-time flashing or a bricked badge. Full procedure in [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md); `./scripts/burn.sh` walks through it.

```sh
# Power off → hold FEL → power on → release. Then, in a clone of gworkman/usb_fel_loaders:
./launch.sh trellis
# Back here:
./scripts/burn.sh
```

If `usb_bulk_send() ERROR -1`: let it sit in FEL a few seconds, use a known-good USB-C **data** cable, or `brew reinstall libusb`.

## Hardware Quick Reference

- Board: **Trellis** (prototype "Wisteria"), Allwinner T113-S4 (sun8i-r528), 2× Cortex-A7, 256 MB.
- Display: 400×300 e-ink, UC8276 controller; a grayscale draw takes ~1.3 s idle, ~4 s under refill load.
- Buttons: BTN_1 (A, skip), BTN_2 (B, unused).
- WiFi: Realtek RTL8188FU on USB, **2.4 GHz only**, power-gated by `WIFI_EN` (PB2).
- Storage: 484 MiB eMMC; rootfs squashfs A/B, `/data` ext4.
- SSH: `wisteria.local`, user `nerves`, password `nerves`; works over the USB cable (`usb0`) regardless of WiFi.

## Gotchas Worth Remembering

- **Typst needs `:eex` in `extra_applications`.** The typst dep evaluates templates through EEx without declaring it. Removing `:eex` compiles fine and then crashes the screen on its first draw, which takes the whole app down (happened 2026-10-10).
- **If the screen crash-loops, the app stops and the badge freezes silently** on its last image: shoehorn keeps the VM (and SSH) alive, but nothing restarts `name_badge`. Check with `Application.started_applications()` and `RingLogger.grep(~r/terminating/)`.
- **Never leave a `GenServer.call` on the render path at its 5 s default.** The refill saturates both cores; a blown timeout once caused a reset loop. `Display` (30 s draw / 60 s render) and `ArtCache` (30 s) carry explicit timeouts. `EInk.draw/2` and `EInk.clear/2` hardcode 5 s, so `Display` calls the `EInk` GenServer directly.
- **BEAM monotonic time is negative** (~−576×10⁹ ms at boot). Never compare `System.monotonic_time/1` against a literal `0`; this bug once silently disabled refills.
- **Typst templates use Elixir interpolation `#{var}`, not EEx tags.** A leading `#` on the first line crashes the renderer. Elixir drops unknown escapes (`"\_"` is `"_"`), so Typst escapes need a double backslash.
- **WiFi is off on battery.** To SSH in: plug in USB power (WiFi back within ~10 s) or SSH over the USB cable.
- **`mix` on PATH is a mise shim, and mise's config env wins over an `export`.** Use `mise exec -- env MIX_TARGET=trellis mix ...` (what the scripts do).
- **`mix upload` doesn't exist here**, despite what `mix firmware` prints. Use `./scripts/push.sh`.
- **After a reflash**, `ssh-keygen -R wisteria.local`. The reboot takes 2-3 minutes; ping returns before SSH. Keep USB power on during flashes.
- **Clock drift after boot** causes TLS "Certificate Expired" errors; self-heals via NTP, or `NervesTime.restart_ntpd()`.
- **WiFi power-on glitches the storage bus**: 162 of 163 logged `sunxi-mmc 4020000.mmc: data error` lines landed within 5 s of a WiFi power-on (the chip and eMMC likely share the 3.3 V rail). The kernel retries; across two months no write was lost and ext4's error count is 0. Watch, don't handle.

## Git

- `origin` → `git@github.com:markomitranic/name_badge.git`, Marko's repo. **Push directly to `origin/main`** once work is done and verified; no PR flow.
- `upstream` → `protolux-electronics/name_badge`. Kept for reference only; don't merge from it, the codebases no longer line up.

## Reference Docs (`docs/`)

Paper documentation of the layers below the app, extracted from upstream repos. Each file opens with a table of contents.

- [`docs/bootloader_uboot.md`](./docs/bootloader_uboot.md): U-Boot 2025.04 + SPL, eMMC partition layout, A/B slot selection. Tags: bootloader, partitions, a-b-slots, brick-risk.
- [`docs/device_tree_kernel.md`](./docs/device_tree_kernel.md): Linux 6.12.32 config and the `sun8i-t113s-trellis.dts` device tree (every GPIO, SPI bus, regulator). Tags: kernel, device-tree, gpio, pinout, wifi-driver.
- [`docs/nerves_system_trellis.md`](./docs/nerves_system_trellis.md): the Buildroot-based Nerves system (rootfs, erlinit, fwup, toolchain). Tags: nerves-system, buildroot, fwup, ota.
- [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md): FEL recovery toolkit and procedure. Tags: flash, brick, recovery, fel.
- [`docs/elixir_application.md`](./docs/elixir_application.md): **stale**. Describes the original multi-screen conference app; its runbook parts (flashing, SSH, recovery) still mostly apply, its application parts don't.

## When Answering Hardware / Firmware Questions

Order of authority:

1. **This repository** (`lib/`, `config/`, `mix.exs`, `priv/typst/`): ground truth for the app.
2. **`docs/`**: ground truth for the layers below the app.
3. **Upstream repos**, re-cloned temporarily for source-level detail: `protolux-electronics/nerves_system_trellis`, `gworkman/usb_fel_loaders`, `protolux-electronics/eink`.
4. **General Nerves/Elixir knowledge.**
