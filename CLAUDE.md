# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What This Is

Firmware for a single-purpose, fully offline Spotify cover display, built on the Protolux Trellis e-ink badge. It shows one album from the owner's (Marko's) Spotify saved library at a time in a cassette-spine layout, rotates every 5 minutes, and skips on button A. Button B does nothing. There are no menus, settings, splash, status bar or host simulator, by design.

The badge never touches a network. The library is mirrored and every frame rendered on the laptop (`scripts/sync.exs`), committed under `.spotify/`, and copied to the badge over USB-C (`scripts/push_covers.exs`). The WiFi chip is held unpowered from boot and the second CPU core is taken offline.

**Priorities, in order: stability, battery life, simplicity.** Before adding anything, ask whether a 1-click utility device needs it. Removed features live in git history (on-device Spotify client + refill bursts + WiFi power policy, multi-screen `Screen`/`ScreenManager` framework, `Layout` status bar, Settings → WiFi wizard + System Info, `TimezoneService`/tzdata, NervesHub link, `GrayTune` LUT calibration harness, LiveView simulator + mocks, power measurement scripts).

The repo started as a fork of [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) (Goatmire 2025 conference badge) and has diverged completely. Module names still carry the `NameBadge` prefix and the release is still `name_badge`/product `goatmire`; renaming isn't worth the churn (the product name feeds firmware metadata).

## Architecture

### Badge (device-only; the app does not build for `MIX_TARGET=host`)

Supervision tree (`NameBadge.Application`, one_for_one): `EInk` (panel driver singleton, configured via `config :eink`) → `NameBadge.Display` (serializes draws, PNG → `EInk`) → `NameBadge.Screen` → `NameBadge.Button` (BTN_1 falling edge → `:button_pressed` to the screen). Plain modules: `Battery` (stateless ADC reads + discharge curve, for SSH), `Diagnostics` (monitoring, off).

**Boot** (`Application.start/2`): silence the red status LED, drive `WIFI_EN` high (off, active-low on this RTL8188FU board), drop the BEAM to one scheduler and write `0` to `/sys/devices/system/cpu/cpu1/online`. No splash: the panel holds its last image unpowered.

**`Screen`**: shuffles `/data/covers/*.png` and draws one every 5 minutes with `mode: :grayscale, dither: false`; when the pass ends it reshuffles, so the library plays once before repeats. Covers deleted since the shuffle are skipped. Button presses rotate immediately and drop presses that queued during the ~1.3 s draw. `Screen.reload/0` (called by the push script) rescans and shows a fresh cover. An empty `/data/covers` shows `priv/no_covers.png` and waits for a reload.

### Laptop (`scripts/`)

**`sync.exs`** (`Mix.install` with req, typst 0.3.2, dither 0.2.4, pinned to the badge's versions):

1. `Sync.Library`: refresh-token → access token, pages `/v1/me/albums` (50 per call), writes `.spotify/library.json` (one JSON object per line for clean diffs), downloads missing 640 px originals to `.spotify/originals/<id>.jpg`, deletes originals and frames of albums no longer saved. Warns if Spotify rotates the refresh token.
2. `Sync.Render` + `Sync.Frame`: renders `.spotify/rendered/<id>.png` for albums without one, in parallel (~1 min for the whole library). `@recipe` in `Sync.Frame` is stored in `.spotify/rendered/.recipe`; any change re-renders everything, so frames never mix recipes. `--render-only` skips phase 1.

**Frame recipe** (current, chosen Oct 2026 over Stucki/Floyd-Steinberg/Atkinson in sRGB and the driver's own Sierra): resize to 300×300 → grayscale → 1-99% percentile contrast stretch → gamma 2.2 to linear light → Stucki dither against the panel's measured reflectance (0 / 9.1% / 45.7% / 100% of white, i.e. linear 0/23/117/255) via `Dither.dither(palette: ...)` → map those back to the levels the badge addresses (0/85/170/255) → Typst composes the spine (Poppins + per-glyph Noto Sans JP fallback, fonts in `scripts/fonts`, on macOS Typst also sees system fonts) → every pixel snapped to {0, 85, 170, 255} with the eink driver's own thresholds (42/128/213), so spine text stays crisp and the badge never re-dithers. Dithering in linear light keeps far more midtone and shadow detail on photos than dithering the sRGB values. The calibrated UC8276 waveform puts the two mid grays at sRGB 85/170, so an on-screen view of a frame is a faithful preview apart from e-ink's lower contrast.

**`push_covers.exs`**: Erlang `:ssh`/`:ssh_sftp` straight to `nerves@wisteria.local`. Runs an Elixir snippet on the badge that clears stale `.part` files and prints `name md5` per frame, uploads new/changed frames as `<id>.png.part` + rename (atomic for the screen), deletes extras, then calls `NameBadge.Screen.reload()`. Full library ≈ 73 MB; first push ~1.5 min, a no-op check ~13 s.

## Power

- **WiFi is never powered.** No `wlan0` config, no power manager; `WIFI_EN` is driven to its off level at boot. A stale persisted `wlan0` config may still sit in `/data/vintage_net`; with the chip off the interface never appears, so it's inert.
- **CPU1 offline.** The July 2026 A/B test hinted ~10% lower drain with CPU1 offline but never completed its control leg. Unmeasured since.
- **No real suspend exists on this board**: `/sys/power/mem_sleep` offers only `s2idle`, the RTC has no `wakealarm`, there is no cpufreq (fixed clock, fixed regulators) and no cpuidle driver. Timed power-cycling would need external hardware (no PMIC with a wake timer).
- **`Battery` is stateless**: one sysfs read per call. The discharge curve (`Battery.percentage_at/1`) comes from two full drains with WiFi on (6-7 h, dead at ~3.35 V); offline runtime will be far longer and the curve's time scale no longer applies, only its voltage → charge shape.
- **Red status LED silenced at boot** (~0.5 mA). Re-enable: `File.write!("/sys/class/leds/red:status/trigger", "heartbeat")`.

## Monitoring (off by default)

`NameBadge.Diagnostics` holds three recorders, each enabled by uncommenting one line in `NameBadge.Application`:

- `Diagnostics.attach_disk_logger()`: warning+ logs and crash reports to `/data/debug.log` (2×512 KB). RingLogger is RAM-only and loses everything on reboot.
- `Diagnostics.log_boot()`: a `ts,boot,voltage` line per boot in `/data/power.log`. A boot with no graceful `/data/shutdown.txt` update means a hard reset (watchdog, brownout, power cut). Timestamps are wrong without NTP.
- `NameBadge.Diagnostics` child: minute health samples (load, memory, scheduler queues, key process mailboxes, voltage) to `/data/health.jsonl` (2×2 MB) plus the last two boots' `dmesg`. `Diagnostics.measure/2` wraps every panel draw; while the recorder is off it costs a dropped cast.

To measure offline battery life: enable the child, run a full drain, pull `/data/health.jsonl` over USB.

## Commands

Everything goes over a USB-C **data** cable (`usb0`, `wisteria.local`). A charger-only cable or port gives no link.

```sh
mise exec -- elixir scripts/sync.exs          # mirror library + render missing frames
mise exec -- elixir scripts/push_covers.exs   # mirror frames onto the badge
./scripts/build.sh && ./scripts/push.sh       # build + flash firmware (password: nerves)
./scripts/ssh.sh                              # IEx on the badge
./scripts/burn.sh                             # USB-FEL first flash / brick recovery
./scripts/clean.sh                            # wipe _build + deps
SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=... elixir scripts/spotify_auth.exs  # one-time OAuth
```

Compile check without building firmware: `mise exec -- env MIX_TARGET=trellis mix compile`.

On the badge:

```elixir
NameBadge.Battery.voltage()                 # e.g. 3.82 (> 4.5 on USB)
NameBadge.Battery.percentage()              # 0-100 along the measured curve
NameBadge.Screen.reload()                   # rescan /data/covers, show a fresh cover
send(NameBadge.Screen, :button_pressed)     # same as button A
File.read!("/sys/devices/system/cpu/online")  # "0" when CPU1 is parked
RingLogger.grep(~r/terminating|Screen/)     # recent logs (RAM only)
```

## Configuration

`mise.toml` pins `MIX_TARGET=trellis` and the toolchain. `.mise.local.toml` (git-ignored) holds the Spotify secrets, read only by `scripts/sync.exs`; nothing secret is compiled into the firmware:

```toml
[env]
SPOTIFY_CLIENT_ID = "..."
SPOTIFY_CLIENT_SECRET = "..."
SPOTIFY_REFRESH_TOKEN = "..."
```

## Toolchain Prerequisites (macOS)

1. `mise install` (Elixir 1.19.5 / Erlang 28.3).
2. Once per machine:
   ```sh
   mix local.hex --force
   mix local.rebar --force
   mix archive.install hex nerves_bootstrap --force
   ```
3. All required (`pkg-config` for `vintage_net_wifi`'s native build, still pulled in by `nerves_pack`; `coreutils` for `gstat` in `mix firmware`):
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

If `usb_bulk_send() ERROR -1`: let it sit in FEL a few seconds, use a known-good USB-C **data** cable, or `brew reinstall libusb`. A burn can wipe `/data`; re-run `push_covers.exs` afterwards (it only uploads what is missing).

## Hardware Quick Reference

- Board: **Trellis** (prototype "Wisteria"), Allwinner T113-S4 (sun8i-r528), 2× Cortex-A7, 256 MB.
- Display: 400×300 e-ink, UC8276 controller; a grayscale draw takes ~1.3 s.
- Buttons: BTN_1 (A, skip), BTN_2 (B, unused).
- WiFi: Realtek RTL8188FU on USB, power-gated by `WIFI_EN` (PB2, active-low). Unused.
- Storage: 484 MiB eMMC; rootfs squashfs A/B, `/data` ext4 (175 MB, ~70 MB free with the full library).
- SSH: `wisteria.local`, user `nerves`, password `nerves`, over the USB-C gadget link only.

## Gotchas Worth Remembering

- **If the screen crash-loops, the app stops and the badge freezes silently** on its last image: shoehorn keeps the VM (and SSH) alive, but nothing restarts `name_badge`. Check with `Application.started_applications()` and `RingLogger.grep(~r/terminating/)`.
- **A dependency can need an OTP app it doesn't declare.** The typst dep used EEx without listing it; dropping `:eex` from `extra_applications` compiled fine and crashed the screen on its first draw (2026-10-10). After removing anything from the release, check the badge actually draws.
- **Never leave a `GenServer.call` on the render path at its 5 s default.** A grayscale draw measured over 4 s under load and a blown timeout once caused a reset loop. `Display` carries 30 s draw / 60 s render timeouts and calls the `EInk` GenServer directly because `EInk.draw/2` hardcodes 5 s.
- **BEAM monotonic time is negative** (~−576×10⁹ ms at boot). Never compare `System.monotonic_time/1` against a literal `0`.
- **nerves_ssh exec output uses `\r\n` line endings.** Anything parsing it (like `push_covers.exs`) must allow a trailing `\r`.
- **Typst templates use Elixir interpolation `#{var}`, not EEx tags.** A leading `#` on the first line crashes the renderer. Elixir drops unknown escapes (`"\_"` is `"_"`), so Typst escapes need a double backslash.
- **Re-renders churn git.** 1,565 frames ≈ 73 MB; every recipe change rewrites all of them. Iterate on a handful of albums before committing a new recipe.
- **`mix` on PATH is a mise shim, and mise's config env wins over an `export`.** Use `mise exec -- env MIX_TARGET=trellis mix ...` (what the scripts do).
- **`mix upload` doesn't exist here**, despite what `mix firmware` prints. Use `./scripts/push.sh`.
- **After a reflash**, `ssh-keygen -R wisteria.local`. The reboot takes 2-3 minutes; ping returns before SSH.
- **No NTP any more**, so the badge clock is wrong. Nothing displays or depends on it.

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

1. **This repository** (`lib/`, `config/`, `mix.exs`, `scripts/`): ground truth for the app and the laptop pipeline.
2. **`docs/`**: ground truth for the layers below the app.
3. **Upstream repos**, re-cloned temporarily for source-level detail: `protolux-electronics/nerves_system_trellis`, `gworkman/usb_fel_loaders`, `protolux-electronics/eink`.
4. **General Nerves/Elixir knowledge.**
