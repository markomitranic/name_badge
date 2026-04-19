# Elixir Application (`name_badge`)

The only repo worth actively maintaining going forward. Everything below documents the app layer — the user's fork target — plus a substantial runbook for day-to-day operations and recovery.

Cross-refs: [bootloader_uboot.md](./bootloader_uboot.md), [device_tree_kernel.md](./device_tree_kernel.md), [nerves_system_trellis.md](./nerves_system_trellis.md), [usb_fel_loaders.md](./usb_fel_loaders.md).

---

## 1. Table of Contents

1. [Table of Contents](#1-table-of-contents)
2. [What this is](#2-what-this-is)
3. [Upstream provenance & forking](#3-upstream-provenance--forking)
4. [Toolchain](#4-toolchain)
5. [Environment variables](#5-environment-variables)
6. [`mix.exs` dependencies](#6-mixexs-dependencies)
7. [Supervision tree](#7-supervision-tree-namebadgeapplication)
8. [Screen architecture](#8-screen-architecture)
9. [Layout composition](#9-layout-composition)
10. [Rendering pipeline](#10-rendering-pipeline)
11. [EInk driver initialization](#11-eink-driver-initialization)
12. [`priv/typst/` structure](#12-privtypst-structure)
13. [Services on the device](#13-services-on-the-device)
14. [Screens shipped](#14-screens-shipped)
15. [NervesHub integration](#15-nerveshub-integration)
16. [VintageNet configuration](#16-vintagenet-configuration)
17. [SSH access](#17-ssh-access)
18. [Simulator / host mode](#18-simulator--host-mode)
19. [Directory tree](#19-directory-tree)
20. [Common commands](#20-common-commands)
21. [Runbook](#21-runbook)
22. [Repurposing the badge](#22-repurposing-the-badge)
23. [What's NOT in this doc](#23-whats-not-in-this-doc)

---

## 2. What this is

The `name_badge` Elixir/Nerves application is the **product layer** of the Protolux Trellis badge. It is the only repo in the stack that a casual developer should actively modify:

- Bootloader, kernel, device tree, Linux userspace → owned by the Nerves system (`nerves_system_trellis`). You rebuild those only if you need new kernel drivers or to repartition.
- USB FEL loader → used once per device (bare-metal recovery flashing).
- **`name_badge`** → where every screen, service, button binding, status bar icon, and WebSocket client lives. It is where 99% of your fork-and-customize work happens.

The user has already flashed firmware `name_badge 0.3.1` from source and joined the badge to home WiFi. Next step is a fork.

---

## 3. Upstream provenance & forking

| Field | Value |
|---|---|
| Upstream | `https://github.com/protolux-electronics/name_badge.git` |
| Branch | `main` |
| Latest commit (snapshot 2026-04-19) | `77ff545` "Add time to main Layout and make timezone consistent across system (#26)" |
| `mix.exs` version | `0.3.1` |
| Elixir requirement | `~> 1.18` |
| Nerves bootstrap | `~> 1.13` |
| Targets | `[:trellis]` |
| Tags | none yet |

### Forking guidance

1. Fork `protolux-electronics/name_badge` → `<you>/name_badge` on GitHub.
2. `git clone git@github.com:<you>/name_badge.git` into the workspace (replaces the read-only clone).
3. Add upstream as a second remote: `git remote add upstream https://github.com/protolux-electronics/name_badge.git` so you can cherry-pick future fixes.
4. **Do not** rename the OTP app (`:name_badge`) on day one — you'll pay for it in config paths, release cookies, and KV keys. Rename only once your variant is stable. See [§22](#22-repurposing-the-badge).
5. Copy `DISCORD.md` and `name_badge_ssh_keys/` notes from the workspace root; they are not in the upstream repo.

---

## 4. Toolchain

Pinned via `mise.toml` at the repo root:

```toml
[env]
MIX_TARGET = "trellis"

[tools]
elixir = "1.19.5-otp-28"
erlang = "28.3"
```

- `MIX_TARGET=trellis` is the default. Override per-command for simulator (`MIX_TARGET=host iex -S mix`).
- `mise install` inside `name_badge/` fetches Elixir + Erlang. Anything else (`xz`, `fwup`, `squashfs`, `sunxi-tools`) installs via Homebrew — see [§21 Runbook](#21-runbook).
- `.mise.local.toml` is git-ignored and holds `DEVICE_SETUP_URL`, `NERVES_WIFI_SSID`, `NERVES_WIFI_PASSPHRASE`, and (optionally) `NH_PRODUCT_KEY`/`NH_PRODUCT_SECRET`.

---

## 5. Environment variables

| Var | Required | Default | Read in | Effect |
|---|---|---|---|---|
| `DEVICE_SETUP_URL` | **yes** (compile-time) | — | `config/config.exs` | Hostname of the Phoenix backend (Goatmire). Powers `NameBadge.Socket` (Slipstream WSS), gallery push, survey topic. `config/config.exs` **raises** if unset. |
| `NH_PRODUCT_KEY` | no | — | `mix.exs` (conditional dep) + `config/target.exs` | Enables `:nerves_hub_link` at build time. If absent, NervesHub is inert. |
| `NH_PRODUCT_SECRET` | no | — | `config/target.exs` | Shared-secret pair with `NH_PRODUCT_KEY`. |
| `NERVES_WIFI_SSID` | no | — | `config/target.exs` (via KV) | Seed credential baked into `nerves_pack` KV; read on first boot by `NameBadge.Application`. |
| `NERVES_WIFI_PASSPHRASE` | no | — | ditto | Paired with `NERVES_WIFI_SSID`. |
| `CALENDAR_URL` | no | `http://pirate.monkeyness.com/calendars/Moons-Seasons.ics` | `config/config.exs` | iCal URL used by `NameBadge.CalendarService`. |
| `CALENDAR_REFRESH_INTERVAL` | no | `"30"` (minutes) | `config/config.exs` | Cadence for re-fetching the iCal URL. |
| `MIX_TARGET` | effectively required | `trellis` (via `mise.toml`) | Mix | Must match the artifact you want (`trellis` for device, `host` for simulator). |

Compile-time gate:

```elixir
device_setup_url =
  System.get_env("DEVICE_SETUP_URL") ||
    raise "System environment variable `DEVICE_SETUP_URL` was not set..."
```

If you rip out `NameBadge.Socket` entirely, also delete or gate this raise — otherwise you can't compile without a dummy value.

---

## 6. `mix.exs` dependencies

**Release settings:** cookie `"name_badge_cookie"`, `include_erts: &Nerves.Release.erts/0`, steps `[&Nerves.Release.init/1, :assemble]`, `strip_beams: true` on `:prod`.

### Core / all targets

| Dep | Version | Purpose |
|---|---|---|
| `nerves` | `~> 1.10` | core Nerves framework |
| `shoehorn` | `~> 0.9.1` | fault-tolerant startup supervisor |
| `ring_logger` | `~> 0.11.0` | in-memory ring-buffer logger |
| `toolshed` | `~> 0.4.0` | IEx helpers (`hex/1`, `fw/1`, `reboot/0`) |

### UI / rendering

| Dep | Version | Purpose |
|---|---|---|
| `typst` | `~> 0.3` | Typst → PNG via Rust NIF (pre-compiled since 2025-09-27, no Rust toolchain needed) |
| `dither` | `~> 0.1.1` | PNG → grayscale → raw 1-bit (Rust NIF) |
| `qr_code` | `~> 3.2.0` | QR generation (setup screen, WiFi credentials) |

### Networking / comms

| Dep | Version | Purpose |
|---|---|---|
| `slipstream` | `~> 1.2` | Phoenix Channels client (WSS to `DEVICE_SETUP_URL`) |
| `req` | `~> 0.5` | HTTP client (calendar, weather, whenwhere) |
| `vintage_net_wizard` | github `nerves-networking/vintage_net_wizard` | AP-mode WiFi setup flow |

### Calendars / time

| Dep | Version | Purpose |
|---|---|---|
| `tzdata` | `~> 1.1` | tzdb (stored in `/data/tzdata` on device) |
| `icalendar` | `~> 1.1` | iCal parsing for calendar screen |

### Host-only (simulator)

| Dep | Version | Purpose |
|---|---|---|
| `phoenix_playground` | `~> 0.1.8` | LiveView simulator on `localhost:4000` |
| `nerves_runtime` | `~> 0.13.0` | In-memory KV backend mock |

### Device-only (non-host)

| Dep | Version | Purpose |
|---|---|---|
| `nerves_hub_link` | `~> 2.9` (conditional `runtime: @nerves_hub_configured?`) | OTA client; inert without `NH_PRODUCT_KEY` |
| `nerves_pack` | `~> 0.7.1` | bundles mDNS, motd, SSH, NTP, VintageNet defaults |
| `circuits_spi` | `~> 2.0` | SPI bus (e-ink display) |
| `circuits_gpio` | `~> 2.1.3` | GPIO (buttons, reset, DC, busy, WiFi enable) |
| `eink` | github `protolux-electronics/eink` | UC8276 driver abstraction |
| `nerves_system_trellis` | `~> 0.3.0` | target Linux system |

Rust toolchain is **no longer required** on `main` (both `typst` and `dither` ship pre-compiled NIFs for the Trellis triple).

---

## 7. Supervision tree (`NameBadge.Application`)

Three branches determined at runtime (`Mix.target/0` via `NameBadge.target()`):

```
NameBadge.Supervisor
├── [all targets]
│   ├── NameBadge.Config                        # JSON state in /data/config.json
│   ├── Phoenix.PubSub (:name_badge_pubsub)
│   ├── NameBadge.Registry                      # button dispatch + screen lookup
│   ├── NameBadge.Display                       # owns EInk handle
│   ├── NameBadge.ScreenManager                 # navigation stack
│   ├── NameBadge.Weather                       # OpenMeteo poller
│   └── NameBadge.CalendarService (if CALENDAR_URL)
│
├── [:host]
│   ├── NameBadge.DisplayMock                   # PubSub-based frame broadcaster
│   ├── NameBadge.BatteryMock
│   └── PhoenixPlayground → NameBadge.PreviewLive
│
└── [:trellis]
    ├── NameBadge.Battery                       # ADC reader
    ├── NameBadge.ButtonMonitor                 # GPIO interrupts
    ├── NameBadge.TimezoneService               # whenwhere + persist
    ├── NameBadge.Socket                        # Slipstream WSS
    └── WiFi bootstrap task (see below)
```

### WiFi bootstrap

On first boot (target only), the application reads two KV entries written at firmware-build time from `NERVES_WIFI_SSID` / `NERVES_WIFI_PASSPHRASE`:

```elixir
case {Nerves.Runtime.KV.get("wifi_ssid"), Nerves.Runtime.KV.get("wifi_passphrase")} do
  {ssid, pass} when is_binary(ssid) and ssid != "" ->
    VintageNetWiFi.quick_configure(ssid, pass)
  _ -> :ok
end
```

`quick_configure/2` writes through `VintageNet.configure/3` into persistent storage — changes survive reboots and supersede what's baked into the firmware. So re-flashing isn't needed to switch networks.

---

## 8. Screen architecture

### `NameBadge.Screen` (GenServer behavior)

Every UI page is a module implementing:

| Callback | Purpose |
|---|---|
| `mount(args, assigns)` | initial state; returns `{:ok, assigns}` |
| `render(assigns)` | returns **PNG binary**, **Dither reference**, or **Typst string** (see dispatch rules below) |
| `handle_button(button, assigns)` | `:button_1` / `:button_2` / `{:long, :button_2}` |
| `handle_info(msg, assigns)` | generic GenServer info (timers, PubSub) |
| `terminate(reason, assigns)` | cleanup (e.g. cancel timers) |

### `render/1` dispatch (how `NameBadge.Display` decides the pipeline)

| Return shape | Pipeline taken |
|---|---|
| binary starting with bytes `<<137, 80, 78, 71>>` (PNG magic) | treated as a pre-rendered PNG → Dither decode → pack → EInk.draw |
| `%Dither{...}` reference | already in raw-image form → pack → EInk.draw |
| any other binary (treated as Typst source) | Layout wrap → Typst.render_to_png! → Dither → pack → EInk.draw |

### `NameBadge.ScreenManager`

Holds a **stack** of `{module, args}` tuples. Navigation primitives:

- `push(screen_module, args)` — descend into a submenu
- `pop/0` — return; also triggered by long-press on button B (`{:long, :button_2}`)
- `replace(screen_module, args)` — swap without growing the stack (used from TopLevel when picking a "default" screen)

Button events are published on `NameBadge.Registry` (`Registry.dispatch(NameBadge.Registry, key, ...)`) — currently `:button_1` and `:button_2`. The ScreenManager translates long-press-B into `:back` before anything else sees it.

---

## 9. Layout composition

`NameBadge.Layout` wraps every Typst-returning screen. Two entry points:

| Function | When to use |
|---|---|
| `root_layout/2` | full-bleed screens (Gallery, Snake). No status bar, no button hints. |
| `app_layout/2` | normal screens. Injects status bar + button hints + page chrome. |

### Page geometry

- Page: **400 pt × 300 pt** (matches 1-bpp e-ink resolution)
- Margin: **32 pt** all sides
- Default font: **Poppins** size 20 weight 500
- Anchors: `#place(top + right, …)` for the status bar; `#place(bottom + center, …)` for button hints.

### Status bar — `icons_markup/0`

Built as a Typst `stack(dir: ltr, ...)` of fixed-size `image("images/icons/*.png")` calls. Each icon is ~16 pt square. Order:

1. Time (`HH:MM` in the configured timezone)
2. Battery (icon picked by voltage)
3. WiFi (filled or slash)
4. Link (setup-URL socket connected or slash)

Battery thresholds (voltages):

| Voltage | Icon |
|---|---|
| Charging detected (`> 4.5 V` on the raw ADC) | `battery-charging.png` |
| `> 4.0 V` | `battery-100.png` |
| `> 3.8 V` | `battery-75.png` (or closest shipped level) |
| `> 3.6 V` | `battery-50.png` |
| `> 3.4 V` | `battery-25.png` |
| else | `battery-0.png` |

### Adding a new status-bar icon

1. Drop a ~16 pt square PNG into `priv/typst/images/icons/`.
2. Open `lib/name_badge/layout.ex` and add **one** line inside the `stack(dir: ltr, ...)` in `icons_markup/0`:
   ```typst
   image("images/icons/my_icon.png", width: 16pt, height: 16pt),
   ```
3. Every screen using `app_layout/2` picks it up automatically. No other change needed.

### Button hints markup

Two circles (A and B) along the bottom with action labels sourced from `screen.assigns.button_hints` (a `{a_label, b_label}` tuple). The ScreenManager auto-appends "back" to the B hint when the stack depth is > 1.

---

## 10. Rendering pipeline

```
┌───────────────────────────────────────────────────────────────────────┐
│  Screen.render/1                                                      │
│     │                                                                 │
│     ├─► PNG binary (magic 137,80,78,71) ───────────┐                  │
│     │                                              │                  │
│     ├─► %Dither{} reference ──────────────────┐    │                  │
│     │                                         │    │                  │
│     └─► Typst string                          │    │                  │
│              │                                │    │                  │
│              ▼                                │    │                  │
│    NameBadge.Layout.app_layout/2              │    │                  │
│              │                                │    │                  │
│              ▼                                │    │                  │
│    NameBadge.Display.render_typst/2           │    │                  │
│              │                                │    │                  │
│              ▼                                │    │                  │
│    Typst.render_to_png!(template, [],         │    │                  │
│      root_dir:   app_dir/priv/typst,          │    │                  │
│      extra_fonts:[app_dir/priv/typst/fonts])  │    │                  │
│              │ (returns list of PNG binaries; │    │                  │
│              │  app takes first)              │    │                  │
│              ▼                                │    │                  │
│          PNG binary ◄─────────────────────────┘    │                  │
│              │                                     │                  │
│              ▼                                     │                  │
│    Dither.decode!/1                                │                  │
│    Dither.grayscale!/1                             │                  │
│    Dither.to_raw!/1         ◄──────────────────────┘                  │
│              │                                                        │
│              ▼                                                        │
│    pack_bits/1  (8 pixels → 1 byte, threshold 127)                    │
│              │                                                        │
│              ▼                                                        │
│    EInk.draw(handle, packed, :partial | :full)                        │
│              │                                                        │
│              ▼                                                        │
│    SPI on /dev/spidev0.0   +   GPIO DC/RESET/BUSY                     │
│              │                                                        │
│              ▼                                                        │
│         UC8276 ↔ 400×300 1-bpp e-ink panel                            │
└───────────────────────────────────────────────────────────────────────┘
```

**:partial vs :full** — full refresh does the "flash black-white-black" dance (~2 s, no ghosting). Partial refresh is ~300 ms, higher throughput, accumulates ghost pixels after ~10 frames. Screens that change frequently (Snake, scroll views) choose `:partial` and schedule a periodic full refresh.

---

## 11. EInk driver initialization

On target boot, `NameBadge.Display.init/1` runs once:

```elixir
{:ok, handle} =
  EInk.new(EInk.Driver.UC8276,
    dc_pin:     "EPD_DC",
    reset_pin:  "EPD_RESET",
    busy_pin:   "EPD_BUSY",
    spi_device: "spidev0.0"
  )

EInk.clear(handle, :white)
EInk.draw(handle, boot_splash_raw, :full)   # priv/typst/images/logos.svg via Typst
Process.sleep(3_000)
```

GPIO labels resolve through the kernel's pinctrl name table (see [device_tree_kernel.md](./device_tree_kernel.md)). `spidev0.0` is the only SPI bus exposed — no chip-select multiplexing.

---

## 12. `priv/typst/` structure

```
priv/typst/
├── images/
│   ├── logos.svg                # boot splash
│   ├── arrow.svg                # tutorial pointer
│   ├── tigris_logo.svg          # Goatmire sponsor logo
│   └── icons/
│       ├── battery-0.png
│       ├── battery-25.png
│       ├── battery-50.png
│       ├── battery-75.png
│       ├── battery-100.png
│       ├── battery-charging.png
│       ├── wifi.png
│       ├── wifi-slash.png
│       ├── link.png
│       ├── link-slash.png
│       └── exclamation.png
└── fonts/
    ├── Poppins-Thin.ttf        (+ Italic)
    ├── Poppins-ExtraLight.ttf  (+ Italic)
    ├── Poppins-Light.ttf       (+ Italic)
    ├── Poppins-Regular.ttf     (+ Italic)
    ├── Poppins-Medium.ttf      (+ Italic)   ← default UI weight
    ├── Poppins-SemiBold.ttf    (+ Italic)
    ├── Poppins-Bold.ttf        (+ Italic)
    ├── Poppins-ExtraBold.ttf   (+ Italic)
    ├── Poppins-Black.ttf       (+ Italic)
    ├── NewAmsterdam.ttf                      ← display / "hero" text
    └── Silkscreen.ttf                        ← bitmap-style accents
```

**Typst invocation:**

```elixir
Typst.render_to_png!(template_string, [],
  root_dir:    Path.join(:code.priv_dir(:name_badge), "typst"),
  extra_fonts: [Path.join([:code.priv_dir(:name_badge), "typst", "fonts"])]
)
```

Gotchas:
- Templates are **Typst, not EEx**. Use `#{var}` Elixir interpolation. Never `<%= %>`.
- A leading `#` on the first Typst line crashes the renderer (input-escape bug). Start with blank/comment/text first.

---

## 13. Services on the device

### `NameBadge.Battery`

ADC reader at `/sys/bus/iio/devices/iio:device0/in_voltage0_raw`.

| Parameter | Value |
|---|---|
| ADC width | 12-bit (0–4095) |
| Reference voltage | 1.8 V |
| Voltage divider ratio | `(453 kΩ + 51 kΩ) / 51 kΩ ≈ 9.8823529412` |
| Poll interval | 500 ms |
| Low-pass filter | `v_new = 0.9 * v_prev + 0.1 * v_raw` |
| Charging test | `voltage > 4.5 V` |
| Percentage mapping | linear between **3.0 V (0%)** and **4.2 V (100%)**, clamped |

Formula:
```
V = (raw / 4095) * 1.8 * 9.8823529412
```

### `NameBadge.ButtonMonitor`

Uses `Circuits.GPIO.open("BTN_1" | "BTN_2", :input)` with `set_interrupts(:both)`. On press/release:

- Rising edge → record timestamp.
- Falling edge → compute duration.
  - `< 500 ms` → short press → dispatch `:button_1` or `:button_2`.
  - `>= 500 ms` → long press → dispatch `{:long, :button_N}`.

Threshold configurable via app env (`:name_badge, :long_press_ms`); default **500 ms**.

### `NameBadge.Display`

GenServer, single point of contact for `EInk`. Public API:

- `render_typst(template_string, opts)` — full pipeline from Typst string.
- `render_png(png_binary, opts)` — skip Typst, start at Dither.
- `clear(:white | :black)`
- `full_refresh/0` — flush ghosting.

Serializes all writes through its mailbox so concurrent screens can't corrupt a frame.

### `NameBadge.Wifi`

Implements `VintageNet.PowerManager`. Owns the `WIFI_EN` GPIO (board pin PB2). Handles power cycling for the Realtek RTL8xxxU / RTW8723DU on idle-disconnect and reconnect. Required because the chip wedges occasionally on the sun8i-r528 USB bus.

### `NameBadge.TimezoneService`

Subscribes to `VintageNet.subscribe(["interface", "wlan0", "connection"])`. On transition to `:internet`, fires:

```
GET http://whenwhere.nerves-project.org
→ { "latitude": …, "longitude": …, "timezone": …, "city": … }
```

Persists result into `/data/config.json` via `NameBadge.Config`. Retries 3× with 5 s delay.

### `NameBadge.Weather`

GenServer; polls OpenMeteo:

```
https://api.open-meteo.com/v1/forecast?latitude=…&longitude=…&current=temperature_2m,weather_code&...
```

- Interval: **10 minutes**
- Circuit breaker: opens after **3 consecutive failures**, stays open for **5 minutes** before retrying.
- Backs off to cached values when open.

### `NameBadge.CalendarService`

Only starts if `CALENDAR_URL` is set in build-time config (always defaulted — see [§5](#5-environment-variables)). Uses `Req` to fetch iCal text, `ICalendar` to parse, normalizes events into `%{summary, starts_at, ends_at, all_day?, location}`, caches the next ~30 days in ETS. Refresh interval configurable; default **30 min**.

### `NameBadge.Socket`

Slipstream WebSocket client. URL:

```
wss://<DEVICE_SETUP_URL>/device/websocket
```

On connect joins topic `"survey"`. Handles pushes:

| Event | Payload | Effect |
|---|---|---|
| `device_gallery` | `%{"images" => [url, …]}` | feeds `NameBadge.Gallery` |
| `config:<token>` | config map | merged into `/data/config.json` via `NameBadge.Config` |

### `NameBadge.Config`

JSON persistence. Device path: `/data/config.json`. Host path: `Path.join(System.tmp_dir!(), "name_badge_config.json")`. Keys:

| Key | Type | Default |
|---|---|---|
| `first_name` | string | "" |
| `last_name` | string | "" |
| `greeting` | string | "" |
| `company` | string | "" |
| `greeting_size` | int | 32 |
| `name_size` | int | 48 |
| `company_size` | int | 24 |
| `spacing` | int | 16 |
| `show_tutorial` | bool | true |
| `timezone` | string | "Europe/Stockholm" |
| `latitude` | float | nil |
| `longitude` | float | nil |
| `location_name` | string | nil |

API: `get/1`, `get/2`, `put/2`, `merge/1`. All writes are flushed synchronously; PubSub-broadcast to `:name_badge_pubsub` on changes.

### `NameBadge.Network`

VintageNet query facade so screens don't have to know the property paths.

| Function | Backing call |
|---|---|
| `connected?/1` (iface default `"wlan0"`) | `VintageNet.get(["interface", iface, "connection"]) == :internet` |
| `current_ap/0` | `VintageNet.get(["interface", "wlan0", "wifi", "access_points"])` → first associated |
| `wlan_ip/0` | `VintageNet.get(["interface", "wlan0", "addresses"])` → first IPv4 |
| `usb_ip/0` | same for `usb0` |

On `:host`, all functions return stubbed values (`true`, `"fake-ssid"`, `"127.0.0.1"`).

---

## 14. Screens shipped

All under `lib/name_badge/screen/`:

| Module | Entry point / purpose |
|---|---|
| `NameBadge.Screen.TopLevel` | main menu; button A cycles, button B selects |
| `NameBadge.Screen.NameBadge` | personal info display (the default screen after tutorial) |
| `NameBadge.Screen.Calendar` | Day / Week / Month views; consumes `CalendarService` |
| `NameBadge.Screen.Weather` | OpenMeteo view |
| `NameBadge.Screen.Snake` | 8×8 grid game, demo of partial refresh |
| `NameBadge.Screen.Gallery` | remote images pushed via Socket |
| `NameBadge.Screen.Settings` | submenu index |
| `NameBadge.Screen.Settings.QRCode` | renders setup QR (device URL + ID) |
| `NameBadge.Screen.Settings.SudoMode` | reveals cleartext WiFi creds, IPs, raw ADC |
| `NameBadge.Screen.Settings.SystemInfo` | firmware slot, uptime, free space |
| `NameBadge.Screen.Settings.Tutorial` | 3-page walkthrough on first boot |
| `NameBadge.Screen.Settings.WiFi` | hands off to VintageNetWizard AP-mode portal |

---

## 15. NervesHub integration

- **Dormant by default.** Activates only when both `NH_PRODUCT_KEY` and `NH_PRODUCT_SECRET` are set at build time.
- The conditional is in `mix.exs`:
  ```elixir
  @nerves_hub_configured? not is_nil(System.get_env("NH_PRODUCT_KEY"))
  {:nerves_hub_link, "~> 2.9", runtime: @nerves_hub_configured?}
  ```
- Host: `manage.nervescloud.com`.
- Geo extension enabled (sends last-known location).
- App code **does not** call `NervesHubLink` directly — the link runs autonomously once configured.

---

## 16. VintageNet configuration

From `config/target.exs`:

| Setting | Value |
|---|---|
| `regulatory_domain` | `"00"` (worldwide) |
| `power_managers` | `[{NameBadge.Wifi, [gpio: "WIFI_EN"]}]` |
| Interfaces | `usb0` (`VintageNetDirect`), `eth0` (DHCP), `wlan0` (`VintageNetWiFi`) |
| mDNS (`mdns_lite`) | hosts `[:hostname, "wisteria"]`, TTL 120, services SSH + SFTP + EPMD |

Hostname template is inherited from `nerves_system_trellis` (`wisteria-<serial-suffix>`), but `mdns_lite` also advertises the static alias `wisteria.local`. Over USB-CDC, macOS resolves the alias automatically.

WiFi chip: **Realtek RTL8188FU** (visible in `dmesg` during boot). **2.4 GHz only**.

---

## 17. SSH access

From `config/target.exs`:

```elixir
config :nerves_ssh,
  daemon_option_overrides: [
    {:pwdfun, &NameBadge.ssh_check_pass/2},
    {:auth_method_kb_interactive_data, &NameBadge.ssh_show_prompt/3}
  ]
```

Password callback:

```elixir
def ssh_check_pass(user, pass) do
  expected = Application.get_env(:name_badge, :password, "nerves")
  user == ~c"nerves" and pass == String.to_charlist(expected)
end
```

So the default credentials are **`nerves` / `nerves`**. Override at runtime:

```elixir
Application.put_env(:name_badge, :password, "new-password")
```

Or at build time in `config/target.exs`.

SFTP is enabled via `nerves_pack` defaults. EPMD is advertised on the LAN so `iex --sname foo --cookie name_badge_cookie` from your laptop can attach to the badge remotely.

---

## 18. Simulator / host mode

```sh
MIX_TARGET=host mix deps.get
MIX_TARGET=host iex -S mix
```

The host application starts `PhoenixPlayground` on `http://localhost:4000` and serves `NameBadge.PreviewLive` — a LiveView simulator with:

- Faux 400×300 canvas rendering the latest PNG frame (broadcast via PubSub from `DisplayMock`).
- Two HTML buttons mapped to `:button_1` and `:button_2`.
- A "long press B" button for `:back`.
- A sidebar showing the current screen stack.

Origin: community PR #7 by **matthias-maennich**. If the PR hasn't been merged in your fork, pull it in — it's the fastest iteration loop.

### Host mocks

| Service | Mock |
|---|---|
| `NameBadge.Display` | `NameBadge.DisplayMock` (PubSub broadcasts frames to the LiveView) |
| `NameBadge.Battery` | `NameBadge.BatteryMock` (fixed 4.05 V) |
| `Nerves.Runtime.KV` | `Nerves.Runtime.KVBackend.InMemory` (see `config/host.exs`) |

`config/host.exs`:

```elixir
config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}
```

---

## 19. Directory tree

```
name_badge/
├── config/
│   ├── config.exs         # env-var gating, CALENDAR defaults, tzdata
│   ├── host.exs           # KV mock for simulator
│   ├── target.exs         # device: shoehorn, ssh, vintage_net, mdns_lite, nerves_hub
│   └── provisioning.conf  # per-unit fwup variables
├── lib/
│   ├── name_badge.ex                 # top module; ssh_check_pass/2
│   └── name_badge/
│       ├── application.ex            # supervision tree + WiFi bootstrap
│       ├── battery.ex                # ADC reader + low-pass filter
│       ├── battery_mock.ex           # host mock
│       ├── button_monitor.ex         # GPIO edge detection
│       ├── calendar_service.ex       # iCal fetch/parse
│       ├── config.ex                 # JSON persistence
│       ├── display.ex                # Typst → PNG → Dither → EInk
│       ├── display_mock.ex           # host mock (PubSub frames)
│       ├── gallery.ex                # image push from server
│       ├── layout.ex                 # Typst layout + status bar + hints
│       ├── network.ex                # VintageNet facade
│       ├── preview_live.ex           # LiveView simulator UI
│       ├── schedule_api.ex           # Sessionize.com (legacy Goatmire)
│       ├── schedule_updater.ex       # stub (deprecated)
│       ├── screen.ex                 # GenServer behavior
│       ├── screen_manager.ex         # navigation stack
│       ├── socket.ex                 # Slipstream WSS client
│       ├── timezone_service.ex       # geo-based TZ
│       ├── weather.ex                # OpenMeteo + circuit breaker
│       ├── wifi.ex                   # VintageNet.PowerManager
│       └── screen/
│           ├── calendar.ex           # Day/Week/Month
│           ├── gallery.ex
│           ├── name_badge.ex
│           ├── settings.ex
│           ├── settings/qr_code.ex
│           ├── settings/sudo_mode.ex
│           ├── settings/system_info.ex
│           ├── settings/tutorial.ex
│           ├── settings/wifi.ex      # VintageNetWizard integration
│           ├── snake.ex
│           ├── top_level.ex
│           └── weather.ex
├── priv/
│   └── typst/                        # see §12
├── rel/
│   └── vm.args.eex                   # BEAM flags (see below)
├── rootfs_overlay/
│   └── etc/iex.exs                   # motd + Toolshed + RingLogger
├── mix.exs
├── mise.toml
└── README.md
```

### `rel/vm.args.eex` (key flags)

```
+Bc
+C multi_time_warp
-mode embedded
-code_path_choice strict
+sbwt none
+sbwtdcpu none
+sbwtdio none
-kernel shell_history enabled
-heart -env HEART_BEAT_TIMEOUT 30
-noshell
-user elixir
-run elixir start_cli
-elixir ansi_enabled true
-extra --no-halt
--dot-iex /etc/iex.exs
```

- `-heart` triggers a hardware-ish reboot if the BEAM stops responding (watchdog inside the runtime).
- `multi_time_warp` is required so NTP jumps don't crash monotonic callers.
- `embedded` mode loads all beams up front → faster boot, no per-call loading latency.

### `rootfs_overlay/etc/iex.exs`

```elixir
NervesMOTD.print()
use Toolshed
RingLogger.attach()
```

Runs on every fresh IEx prompt, device or SSH.

---

## 20. Common commands

```sh
# Fetch deps
mix deps.get

# Build target firmware (MIX_TARGET=trellis from mise.toml)
mix firmware

# First-time flash (badge in FEL / USB mass-storage mode)
mix burn

# Flash over SSH to a running badge (password: nerves)
cat _build/trellis_dev/nerves/images/name_badge.fw \
  | ssh -s nerves@wisteria.local fwup

# Generate reusable upload script
MIX_TARGET=trellis mix firmware.gen.script
./upload.sh wisteria.local

# SSH into the badge (IEx prompt)
ssh nerves@wisteria.local
```

**`mix upload` does NOT exist** — the `mix firmware` success message is wrong for this project. Use the pipe or `upload.sh`.

Inside a badge IEx session:

```elixir
VintageNet.info()
VintageNet.get(["interface", "wlan0", "connection"])
VintageNetWiFi.quick_configure("ssid", "password")
NervesTime.restart_ntpd()
Application.stop(:nerves_hub_link)
Application.ensure_all_started(:nerves_hub_link)
RingLogger.next
Nerves.Runtime.KV.get_all()
Nerves.Runtime.revert()
Nerves.Runtime.reboot()
```

---

## 21. Runbook

Day-to-day operations + recovery. Recipes, not prose.

### 21.1 Everyday firmware build + flash

**Standard dev loop (laptop on same LAN as badge, badge powered via USB-C):**

```sh
# 1. build
mix firmware

# 2. flash over SSH (preferred)
cat _build/trellis_dev/nerves/images/name_badge.fw \
  | ssh -s nerves@wisteria.local fwup

# 3. wait 2–3 minutes for reboot (NOT 30 seconds)
#    Ping comes back first, SSH after BEAM is up.
ping -c 1 wisteria.local
ssh nerves@wisteria.local
```

**Generate a reusable script once per machine:**

```sh
MIX_TARGET=trellis mix firmware.gen.script
./upload.sh wisteria.local
```

### 21.2 IEx incantations cheatsheet

```elixir
# Network state
VintageNet.info()
VintageNet.get(["interface", "wlan0", "connection"])      # :disconnected | :lan | :internet
VintageNet.get(["interface", "wlan0", "addresses"])
VintageNet.get(["interface", "wlan0", "wifi", "access_points"])

# Change WiFi at runtime (persists!)
VintageNetWiFi.quick_configure("ssid", "password")

# Clock drift / TLS / NervesCloud 401
NervesTime.restart_ntpd()
Application.stop(:nerves_hub_link); Application.ensure_all_started(:nerves_hub_link)

# Logs
RingLogger.next          # newest chunk
RingLogger.tail          # like `tail -f`
RingLogger.grep(~r/wifi/i)

# Firmware / KV
Nerves.Runtime.KV.get_all()
Nerves.Runtime.revert()             # swap active slot; reboots
Nerves.Runtime.reboot()
Nerves.Runtime.factory_reset()

# Toolshed (from /etc/iex.exs)
hex                # print iex prompt hex of last binary
fw "foo.fw"        # inspect a fwup archive
ifconfig           # more readable than VintageNet.info for a glance
```

### 21.3 Switching firmware versions (A/B revert)

Nerves keeps two firmware slots (A and B). A successful fwup writes the inactive slot and swaps on reboot.

```elixir
# From IEx on the device
Nerves.Runtime.revert()
```

Or directly via fwup-ops on the device shell:

```sh
# when currently on B, revert to A:
fwup -t revert.a -d /dev/rootdisk0 /usr/share/fwup/ops.fw
# reverse:
fwup -t revert.b -d /dev/rootdisk0 /usr/share/fwup/ops.fw
```

After `revert()`, the badge reboots into the other slot. If that slot is empty/corrupt, it falls back to the original. You cannot brick via `revert()` alone.

**Rolling back to a stashed `.fw`:**

```sh
cat known_good_0.3.0.fw | ssh -s nerves@wisteria.local fwup
```

Same pipe as a forward upgrade — `fwup` doesn't care about direction.

### 21.4 Deploying a completely different Elixir app

Same hardware, different OTP app. Still uses `nerves_system_trellis` as the base.

1. In the new project's `mix.exs`: `targets: [:trellis]`, add `{:nerves_system_trellis, "~> 0.3.0"}` under `:trellis`.
2. Make sure your `rel/vm.args.eex` matches the one here (especially `-heart`, `-user elixir`).
3. Provide `config/target.exs` with at minimum `:shoehorn` + `:nerves_pack`.
4. `MIX_TARGET=trellis mix firmware`.
5. Flash as usual: `cat .../my_app.fw | ssh -s nerves@wisteria.local fwup`.

fwup checks `meta-platform` (`trellis`) and `meta-architecture` (`arm`), not the app name — so any app built for the same Nerves system slots into the same hardware without FEL.

### 21.5 Simulator → device switch (and back)

Switching `MIX_TARGET` corrupts `_build` because `dither` and `typst` ship arch-specific NIFs.

```sh
# You were running the simulator. Now you want to flash the badge.
mix deps.clean dither typst
MIX_TARGET=trellis mix deps.get
mix firmware
```

If problems persist (e.g. `scrub-otp-release.sh: ERROR: Unexpected executable format`):

```sh
rm -rf _build deps
mix deps.get
mix firmware
```

### 21.6 Bricked device recovery (FEL)

Full procedure in [usb_fel_loaders.md](./usb_fel_loaders.md). Short form:

1. Power off. Hold FEL button. Power on via USB-C. Release FEL after ~1 second.
2. From `usb_fel_loaders/`: `./launch.sh trellis` (erases eMMC, exposes badge as USB mass storage).
3. From `name_badge/` with `MIX_TARGET=trellis` set: `mix burn`.

If `usb_bulk_send() ERROR -1` appears — let the badge sit in FEL for 5 s before `launch.sh`; try a different USB-C data cable (not charge-only); `brew reinstall libusb`.

### 21.7 Lost SSH access / stale host key

```sh
# Stale key after a fresh flash
ssh-keygen -R wisteria.local
```

If ping works but SSH doesn't:
- BEAM hasn't started yet. Wait. Total boot is 2–3 minutes after reflash, not 30 s.
- If it's been > 5 min, check a direct USB ethernet address: `VintageNet.info()` on a serial console would show it, but if you have neither — reflash.

### 21.8 Clock drift (TLS errors, 401s, calendar sync failing)

Symptom: "Certificate Expired" in logs, HTTPS requests fail after boot.

Cause: the badge has no RTC. On power-up its clock is whatever NTP last wrote, minus the powered-off interval.

Fix: once WiFi is up,

```elixir
NervesTime.restart_ntpd()
```

A badge last powered in Sept 2025 will report `2025-09` until WiFi + NTP settle.

### 21.9 NervesHub / NervesCloud 401

Also a clock issue, but the link's own retry isn't fast enough.

```elixir
Application.stop(:nerves_hub_link)
Application.ensure_all_started(:nerves_hub_link)
```

### 21.10 OTA penalty box

Too many reboots during an update parks the device for **~1 minute** (previously 6 h — it's been reduced). Keep it **on USB power** and wait. Do not cycle power repeatedly; each cycle resets the backoff counter in a bad way.

### 21.11 WiFi won't connect (5 GHz gotcha)

- Realtek **RTL8188FU** is **2.4 GHz only**. Visible in `dmesg` at boot (`cat /var/log/dmesg | grep rtl`).
- Dual-band SSIDs (same name on both radios) are fine — badge just ignores 5 GHz.
- 5 GHz-only SSIDs will never work. Add a 2.4 GHz radio on the same SSID/password and it'll associate.
- Check connection state, not "associated":
  ```elixir
  VintageNet.get(["interface", "wlan0", "connection"])
  # => :disconnected | :lan | :internet
  ```
  NTP / NervesCloud / calendar only work at `:internet`.

### 21.12 `_build` corruption after `MIX_TARGET` switch

Symptom: `scrub-otp-release.sh: ERROR: Unexpected executable format` during `mix firmware`.

```sh
mix deps.clean dither typst
MIX_TARGET=trellis mix deps.get
```

If worse:

```sh
rm -rf _build deps
mix deps.get
mix firmware
```

### 21.13 Toolchain drift (xz / fwup / squashfs missing)

`(RuntimeError) Could not find 'xz'` or similar during `mix deps.get`:

```sh
brew install xz fwup squashfs
```

All three are required to unpack the toolchain tarball and build `.fw` images. For FEL only:

```sh
brew install --build-from-source --head lukad/sunxi-tools-tap/sunxi-tools
```

For `mise`-managed Elixir/Erlang drift:

```sh
cd name_badge
mise install
```

**Don't update Hex deps unless forced** — version-pinned `nerves_system_trellis`/`eink` can drift into incompat if you bump major versions casually.

### 21.14 Factory reset

```elixir
# From IEx on device
Nerves.Runtime.factory_reset()
```

Or directly:

```sh
fwup -t factory-reset -d /dev/rootdisk0 /usr/share/fwup/ops.fw
```

Wipes the `/data` partition (config.json, tzdata cache, VintageNet persisted state). Firmware slots untouched.

### 21.15 Save a known-good artifact

1. In your fork: `git tag v-working-YYYY-MM-DD && git push --tags`.
2. Stash the built `.fw` somewhere durable: iCloud Drive, a GitHub release (`gh release create ...`), or git LFS. File name convention: `name_badge-<version>-<gitsha>.fw`.
3. In the tag notes, record:
   - `mise.toml` Elixir/Erlang versions
   - `nerves_system_trellis` version
   - Homebrew `fwup`, `xz`, `squashfs` versions (`brew list --versions`)
4. Also note the `DEVICE_SETUP_URL` used at build (affects `config.exs`).

### 21.16 Environment-variable cheatsheet (reprinted from §5)

| Var | Required | Default |
|---|---|---|
| `DEVICE_SETUP_URL` | **yes** | — |
| `NH_PRODUCT_KEY` | no | — |
| `NH_PRODUCT_SECRET` | no | — |
| `NERVES_WIFI_SSID` | no | — |
| `NERVES_WIFI_PASSPHRASE` | no | — |
| `CALENDAR_URL` | no | `http://pirate.monkeyness.com/calendars/Moons-Seasons.ics` |
| `CALENDAR_REFRESH_INTERVAL` | no | `"30"` (minutes) |
| `MIX_TARGET` | effective | `trellis` (via `mise.toml`) |

---

## 22. Repurposing the badge

You bought the hardware; make it yours.

### Strategy 1 — rip out features

Every feature is a screen module. Delete or stub to shrink.

| To remove | Delete / stub |
|---|---|
| Calendar | `lib/name_badge/screen/calendar.ex` + `calendar_service.ex`. Remove from supervision tree in `application.ex`. Drop `icalendar`, `tzdata` from `mix.exs` (keep tzdata if you want timezones anywhere). |
| Snake | `lib/name_badge/screen/snake.ex`. Remove from TopLevel menu items. |
| Weather | `lib/name_badge/screen/weather.ex` + `weather.ex` service. Drop `req` only if no one else uses it (TimezoneService does). |
| Schedule (Sessionize) | `schedule_api.ex` + `schedule_updater.ex`. Legacy Goatmire; already dormant on main. |

### Strategy 2 — swap the backend

- Point `DEVICE_SETUP_URL` at your own Phoenix server with a `/device/websocket` channel. Keep `NameBadge.Socket` structure; replace `"survey"` topic logic.
- Or rip out Socket + Gallery entirely. Remember to gate / delete the compile-time raise in `config/config.exs`:
  ```elixir
  device_setup_url = System.get_env("DEVICE_SETUP_URL") || raise ...
  ```
  Replace with a default (`System.get_env("DEVICE_SETUP_URL", "")`) or remove the var-read path altogether.

### Strategy 3 — rename the app

Cosmetic but involved. Required edits:

1. `mix.exs` — `app: :name_badge` → `:your_app`.
2. `release.cookie` — `"name_badge_cookie"` → your own (changes distributed Erlang auth; update from laptop too).
3. Application module name: `NameBadge.*` → `YourApp.*` (mass rename; ~40 files).
4. `rel/vm.args.eex` — update any hardcoded references.
5. `:pubsub` names, `Nerves.Runtime.KV` keys prefixed with your app.
6. `mdns_lite` hostname (optional): if you also want to rename `wisteria.local`, that lives in `nerves_system_trellis/rootfs_overlay/etc/erlinit.config` — means you're forking the system too. Leaving it as `wisteria-*` is cosmetically fine and saves a full system rebuild.

### Cautions

- **`DEVICE_SETUP_URL` raises at compile time.** Either always pass a value (even a dummy like `"example.com"`) or edit `config/config.exs` to make it optional.
- **NervesHub activation gate is compile-time** (`@nerves_hub_configured?`). If you add/remove `NH_PRODUCT_KEY` between builds, clear `_build/` to force re-evaluation.
- **Boot splash PNG is large** (`priv/typst/images/logos.svg`). If you swap it, keep it ≤ 50 KB or boot time stretches.
- **Config keys live in JSON on the device** (`/data/config.json`). Removing a key from `NameBadge.Config` does NOT wipe it on upgrade — plan a migration in `Config.init/1`.

---

## 23. What's NOT in this doc

Cross-refs to sibling docs:

- **Bootloader, SPL, BROM, FEL entry, fastboot** → [bootloader_uboot.md](./bootloader_uboot.md)
- **Linux kernel version, device tree, drivers, pin labels** → [device_tree_kernel.md](./device_tree_kernel.md)
- **Nerves system build (Buildroot config, system image layout, fwup.conf, erlinit)** → [nerves_system_trellis.md](./nerves_system_trellis.md)
- **USB FEL recovery flashing (`launch.sh`, `trellis.bin`, FEL button wiring)** → [usb_fel_loaders.md](./usb_fel_loaders.md)

Staleness warning: `DISCORD.md` at the workspace root is a point-in-time snapshot (Sept 2025 – Feb 2026) and is occasionally wrong. When it disagrees with the upstream repo or this doc, the repo / this doc wins.
