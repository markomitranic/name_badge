defmodule NameBadge.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @target Mix.target()

  @impl true
  def start(_type, _args) do
    attach_disk_logger()
    silence_status_led()
    setup_wifi()

    children =
      [
        # Children for all targets
        # Starts a worker by calling: NameBadge.Worker.start_link(arg)
        # {NameBadge.Worker, arg},
        {Registry, name: NameBadge.Registry, keys: :duplicate}
      ] ++ target_children(@target)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NameBadge.Supervisor]
    result = Supervisor.start_link(children, opts)
    log_boot_marker()
    result
  end

  if Mix.target() == :host do
    defp attach_disk_logger(), do: :ok
  else
    # Persists warning+ log entries (including process crash reports) to
    # /data/debug.log so post-mortems survive reboots and power cycles —
    # RingLogger is RAM-only and has eaten crash evidence twice.
    #
    # HANDOFF — the paused stability investigation (2026-07-17). This handler
    # and the boot marker below are the tripwires it left armed. Two distinct
    # incidents are unresolved. (1) A hard board reset at 2026-07-17 04:56 UTC,
    # 13 h into an on-battery drain test (Spotify screen, WiFi duty-cycled,
    # cell at 3.61 V — well above the ~3.25 V death line). It left no
    # /data/shutdown.txt and no erl_crash.dump, and the power.log line being
    # written at that moment was NUL-truncated: the BEAM never exited, so it
    # was a watchdog reset (nerves_heart, VM timeout 30 s) or a power cut —
    # not a BEAM crash. (2) The Spotify screen process crashed on USB power
    # during a stress test (art cache wiped + WiFi hard-cut every 2 min),
    # stranding WiFi off because a crash skips terminate/2. RingLogger lost
    # the stack trace to a reflash before it was read.
    #
    # Running theory: both are software, not battery. Incident 2 proves a
    # screen-crash path exists that has nothing to do with power (it happened
    # while charging). Incident 1's timing is suspicious — it landed inside
    # the expected ArtCache refill window (bursts every ~35–40 min, last one
    # 04:17) — so the prime suspect is the burst path: WiFi power-on / USB
    # re-enumeration / VintageNet reconfigure racing screen rotation and the
    # e-ink grayscale draw. Ruled out: memory leak (BEAM stable at ~62 MB,
    # binaries flat, through 27 forced burst cycles) and brownout for
    # incident 2 (USB-powered). Brownout for incident 1 is unlikely but not
    # formally excluded. A later 27-cycle soak on the fixed firmware (which
    # also fixed the monotonic-time cooldown bug and added the ScreenManager
    # crash fallback) did NOT reproduce either incident.
    #
    # If you are debugging a new incident, start with the evidence, not the
    # code: /data/debug.log (this handler — a screen crash logs its exit
    # reason and stacktrace via ScreenManager), then /data/power.log "boot"
    # lines (a boot line with no graceful /data/shutdown.txt update means a
    # hard reset), then /data/shutdown.txt mtime. A screen crash with a
    # stacktrace is scenario 1: fix the bug it names. A hard reset with an
    # empty debug.log is scenario 2: distinguish watchdog from power by
    # re-enabling the heartbeat LED (silence_status_led/0 below) and watching
    # whether it stops blinking before the reboot — kernel-driven, so LED
    # frozen = kernel/power died, LED beating until reset = VM stall.
    #
    # Reproduction recipe that triggered incident 2 once (on the old code):
    # on the Spotify screen, loop every 2 min — wipe /data/spotify_art, stash
    # VintageNet.get_configuration("wlan0") into the persistent_term key that
    # NameBadge.Network.wifi_on/0 reads, then VintageNet.deconfigure("wlan0",
    # persist: false). Run it on USB first (rules out battery); if clean for
    # ~2 h, repeat on battery below ~3.6 V where incident 1 lived. Full
    # context: git log around 2026-07-16..17 and scripts/power_mark.sh.
    defp attach_disk_logger() do
      _ =
        :logger.add_handler(:disk_log, :logger_std_h, %{
          config: %{file: ~c"/data/debug.log", max_no_bytes: 512_000, max_no_files: 2},
          level: :warning
        })

      :ok
    end
  end

  if Mix.target() == :host do
    defp log_boot_marker(), do: :ok
  else
    # Appends a "boot" line to the power log so hard resets (watchdog,
    # brownout, power switch) stay visible in the record — they leave no
    # shutdown report otherwise. Timestamp may be slightly stale until NTP
    # syncs. Must never take the application down with it.
    defp log_boot_marker() do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      v = NameBadge.Battery.voltage() |> Float.round(4)
      wifi = if NameBadge.Network.wifi_present?(), do: "1", else: "0"
      File.write!("/data/power.log", "#{ts},boot,#{v},#{wifi}\n", [:append])
    rescue
      _ -> :ok
    end
  end

  # List all child processes to be supervised
  defp target_children(:host) do
    [
      {Phoenix.PubSub, name: NameBadge.PubSub},
      NameBadge.DisplayMock,
      NameBadge.BatteryMock,
      NameBadge.TimezoneService,
      {Task.Supervisor, name: NameBadge.TaskSupervisor},
      NameBadge.Spotify.Tokens,
      NameBadge.Spotify.Library,
      NameBadge.Spotify.ArtCache,
      NameBadge.ScreenManager,
      {PhoenixPlayground, live: NameBadge.PreviewLive}
    ]
  end

  # POWER TEST BRANCH: everything except battery + display + the experiment is
  # deliberately not started, so the measurement sees only background noise.
  # No buttons, no screens — power-cycle is the only manual exit.
  defp target_children(_target) do
    [
      NameBadge.Battery,
      # EInk singleton (configured via `config :eink`) must start before Display,
      # which draws the boot frame through it.
      EInk,
      NameBadge.Display,
      NameBadge.PowerTest
    ]
  end

  if Mix.target() == :host do
    defp silence_status_led(), do: :ok
  else
    # The kernel blinks the red status LED (PE9) in a heartbeat pattern from
    # boot. It saves ~0.5 mA average on battery and serves no purpose here,
    # so both the trigger and any mid-blink brightness are cleared.
    defp silence_status_led() do
      _ = File.write("/sys/class/leds/red:status/trigger", "none")
      _ = File.write("/sys/class/leds/red:status/brightness", "0")
      :ok
    end
  end

  if Mix.target() == :host do
    defp setup_wifi(), do: :ok
  else
    defp setup_wifi() do
      kv = Nerves.Runtime.KV.get_all()

      if true?(kv["wifi_force"]) or not wlan0_configured?() do
        ssid = kv["wifi_ssid"]
        passphrase = kv["wifi_passphrase"]

        if not empty?(ssid) do
          _ = VintageNetWiFi.quick_configure(ssid, passphrase)
          :ok
        end
      end
    end

    defp wlan0_configured?() do
      VintageNet.get_configuration("wlan0") |> VintageNetWiFi.network_configured?()
    catch
      _, _ -> false
    end

    defp true?(""), do: false
    defp true?(nil), do: false
    defp true?("false"), do: false
    defp true?("FALSE"), do: false
    defp true?(_), do: true

    defp empty?(""), do: true
    defp empty?(nil), do: true
    defp empty?(_), do: false
  end
end
