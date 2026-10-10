# Spotify Badge

A single-purpose e-ink device: it shows one album from your Spotify saved library at a time, in a cassette-spine layout, and swaps to another every 5 minutes. Press button A to skip. That's the whole interface.

It runs on the Protolux Trellis badge (400×300 e-ink, dual Cortex-A7, Li-ion cell) as Elixir/Nerves firmware. The badge is fully offline: your whole library is rendered on the laptop and copied over USB-C, and the WiFi chip is never powered.

## How it works

```
 laptop                                              badge (offline)
 ──────                                              ───────────────
 scripts/sync.exs                                    /data/covers/<id>.png
   1. Spotify API → .spotify/library.json                   │
      new covers  → .spotify/originals/<id>.jpg             ▼
   2. render     → .spotify/rendered/<id>.png        Screen: shuffled, one per 5 min
                                                            │      ▲
 scripts/push_covers.exs ═══ USB-C (SSH) ══════════▶        ▼      └── button A
   uploads only new/changed frames                   Display ──▶ e-ink, 4 grays
```

- **Everything heavy happens on the laptop.** Each frame is finished there: cover resized, contrast-stretched and dithered to the panel's four calibrated gray levels, spine text typeset. The badge just reads a PNG and draws it.
- **No radio, ever.** The WiFi chip was by far the biggest drain and the only known cause of resets (its power-on surge browned out a weak cell). It's held off at its enable pin from boot.
- **One core.** The second Cortex-A7 is taken offline at boot; a rotation needs a file read and a 1.3 s panel refresh, nothing more.
- **Shuffle without repeats.** The whole library (1,565 albums here) plays once before anything comes back.
- **Nothing to configure on the device.** No menus, no splash, no status bar. It boots straight into the last cover.

## Library

`.spotify/` is the mirrored library and lives in git:

| Path | What |
|---|---|
| `library.json` | Every saved album (id, artist, album, added date, cover URL), one per line |
| `originals/<id>.jpg` | Cover art as downloaded from Spotify (640×640) |
| `rendered/<id>.png` | Finished 400×300 frames, every pixel one of the 4 panel grays |

`scripts/sync.exs` only fetches what changed: new albums get downloaded and rendered, removed ones get deleted. Changing the render recipe (`@recipe` in the script) re-renders everything.

## Setup

**Toolchain (macOS):**

```sh
mise install                                            # Elixir 1.19.5 / OTP 28.3
brew install xz fwup squashfs pkg-config coreutils
mix local.hex --force && mix local.rebar --force
mix archive.install hex nerves_bootstrap --force
```

**Spotify credentials** (used by the laptop script only, never put on the badge): register an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) with redirect URI `http://127.0.0.1:8888/callback`, then:

```sh
SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=... elixir scripts/spotify_auth.exs
```

Paste the three printed variables into `.mise.local.toml` under `[env]`. The file is git-ignored, so it only exists in the checkout you put it in; copy it along to a fresh clone.

## Updating the covers

The whole routine, for when you've saved new albums and haven't touched this in months:

1. **Get current.** `git pull`, then `mise install` if mise complains about a missing tool.
2. **Check the secrets.** `.mise.local.toml` must hold `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET` and `SPOTIFY_REFRESH_TOKEN` (see [Setup](#setup)).
3. **Sync the library:**
   ```sh
   mise exec -- elixir scripts/sync.exs
   ```
   The first run in a while spends a minute or two installing its dependencies. It then fetches your saved albums, downloads covers of new ones, renders their frames and deletes the files of albums you un-saved. If it prints `Spotify rotated the refresh token`, paste the new token into `.mise.local.toml` right away; the old one stops working.
4. **Have a look** (optional): `git status .spotify` lists what changed; new frames are plain PNGs in `.spotify/rendered/`.
5. **Plug the badge in** with a USB-C **data** cable and wait until `ping wisteria.local` answers (up to a minute after plugging in).
6. **Push the frames:**
   ```sh
   mise exec -- elixir scripts/push_covers.exs
   ```
   Only new frames are uploaded and removed albums are deleted, then the badge shows a fresh cover. `Already up to date` means there was nothing to do.
7. **Commit the library:**
   ```sh
   git add .spotify && git commit -m "Sync Spotify library" && git push
   ```

| Problem | Fix |
|---|---|
| `wisteria.local` doesn't answer, or the push times out | The cable or port is charge-only. With a working link the Mac gets a new network interface with a 172.31.x.x address |
| `SPOTIFY_... is not set` | No `.mise.local.toml` in this checkout, or mise doesn't trust it yet (`mise trust`) |
| `Spotify refused the refresh token` | Access was revoked (app deleted, password changed). Re-run `scripts/spotify_auth.exs` and update `.mise.local.toml` |
| Badge shows "No covers yet" | `/data` was wiped, usually by a FEL burn. Push again; a full upload takes about 2 minutes |
| Badge stuck on one cover, button does nothing | Most likely a flat battery: e-ink keeps the last image without power. Charge it. If it still won't rotate, `./scripts/ssh.sh` and `Nerves.Runtime.reboot()` |

To change how frames look, edit `@recipe` in `scripts/sync.exs` and run `mise exec -- elixir scripts/sync.exs --render-only`. Every recipe change re-renders and re-commits all frames (~73 MB), so judge a handful before committing.

## Firmware

Only needed when the badge's code changes:

```sh
./scripts/build.sh && ./scripts/push.sh   # build, then flash over USB (wisteria.local)
./scripts/burn.sh                         # first-time flash or brick recovery over USB-FEL
./scripts/ssh.sh                          # IEx prompt on the badge (password: nerves)
```

| Script | Does |
|---|---|
| `sync.exs` | Phase 1: mirror the Spotify library into `.spotify/`. Phase 2: render missing frames. `--render-only` skips Spotify |
| `push_covers.exs` | Mirror `.spotify/rendered` onto the badge over SSH, by MD5 diff (optional host arg) |
| `build.sh` | `mix deps.get` + `mix firmware` for the trellis target |
| `push.sh` | Flash firmware over SSH (optional host arg). Covers on the badge survive a flash |
| `burn.sh` | USB-FEL flash, with a pre-flight checklist ([`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md)) |
| `ssh.sh` | IEx prompt on the badge |
| `clean.sh` | Wipe `_build` + `deps` when a build gets into a bad state |
| `spotify_auth.exs` | One-time Spotify OAuth to get a refresh token |

Keep the badge plugged in while flashing; the reboot takes 2-3 minutes.

## On the badge

```elixir
NameBadge.Battery.percentage()   # 0-100, along a measured discharge curve
NameBadge.Battery.voltage()      # > 4.5 means USB power
NameBadge.Screen.reload()        # rescan /data/covers and show a fresh cover
send(NameBadge.Screen, :button_pressed)  # skip, same as button A
```

Crash monitoring (disk log, boot markers, minute health samples) is built in but off; [`CLAUDE.md`](./CLAUDE.md#monitoring-off-by-default) explains how to switch it on.

## Hardware and lower layers

The firmware sits on the [`nerves_system_trellis`](https://github.com/protolux-electronics/nerves_system_trellis) Nerves system (Buildroot, Linux 6.12, U-Boot, A/B firmware slots) for the Allwinner T113-S4 SoC. [`docs/`](./docs/) has layer-by-layer reference material: bootloader, kernel and device tree, the Nerves system, and FEL recovery.

## Lineage

Started as a fork of [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge), the conference badge firmware by [Gus Workman](https://github.com/gworkman) / [Protolux Electronics](https://protolux.io), made for [Goatmire 2025](https://goatmire.com/) thanks to [Lars Wikman](https://github.com/lawik) ([talk](https://youtu.be/VFmlNZ_BQHQ)). It has since been rewritten into a different device and no longer tracks upstream. The cover layout is a port of [MusaicFM](https://github.com/obrhoff/MusaicFM).
