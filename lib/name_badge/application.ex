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
    # HANDOFF — the stability investigation. This handler and the boot marker
    # below are the tripwires it left armed, and they caught the screen-crash
    # bug on 2026-09-04: the render path used GenServer.call defaults (5 s),
    # but a grayscale draw that takes 1.3 s idle takes over 4 s while the art
    # refill dithers covers on the other core — and with anti_ghost the screen
    # paid for a white flush plus the draw in one call. Over 5 s, the screen
    # process died, ScreenManager fell back to the menu, the menu render hit
    # the same busy panel and died too, every ~15 s until a hard reset. Both
    # a starved NameBadge.Battery and a busy EInk produced it. Fixed by giving
    # every call on the render path a timeout the hardware can actually meet
    # (see NameBadge.Display and NameBadge.Battery). That also explains the
    # old "screen crashed on USB power during a stress test" report — that
    # test wiped the art cache every 2 min, i.e. it ran the refill nonstop.
    #
    # Still unresolved: a hard board reset at 2026-07-17 04:56 UTC, 13 h into
    # an on-battery drain test (Spotify screen, WiFi duty-cycled, cell at
    # 3.61 V — well above the ~3.25 V death line). It left no
    # /data/shutdown.txt and no erl_crash.dump, and the power.log line being
    # written at that moment was NUL-truncated: the BEAM never exited, so it
    # was a watchdog reset (nerves_heart, VM timeout 30 s) or a power cut —
    # not a BEAM crash. Its timing landed inside the expected ArtCache refill
    # window (bursts every ~35–40 min, last one 04:17), so the suspect is
    # still the burst path: WiFi power-on / USB re-enumeration / VintageNet
    # reconfigure racing the grayscale draw. Ruled out: memory leak (BEAM
    # stable at ~62 MB, binaries flat, through 27 forced burst cycles).
    # Brownout is unlikely but not formally excluded.
    #
    # If you are debugging a new incident, start with the evidence, not the
    # code: /data/debug.log (this handler — a screen crash logs its exit
    # reason and stacktrace via ScreenManager), then /data/power.log "boot"
    # lines (a boot line with no graceful /data/shutdown.txt update means a
    # hard reset), then /data/shutdown.txt mtime. A screen crash with a
    # stacktrace is a plain bug: fix what it names. A hard reset with an
    # empty debug.log is the unresolved one: distinguish watchdog from power
    # by re-enabling the heartbeat LED (silence_status_led/0 below) and
    # watching whether it stops blinking before the reboot — kernel-driven,
    # so LED frozen = kernel/power died, LED beating until reset = VM stall.
    #
    # To put the render path under the load that broke it: on the Spotify
    # screen, loop every 2 min — wipe /data/spotify_art, stash
    # VintageNet.get_configuration("wlan0") into the persistent_term key that
    # NameBadge.Network.wifi_on/0 reads, then VintageNet.deconfigure("wlan0",
    # persist: false). Run it on USB first (rules out battery); if clean for
    # ~2 h, repeat on battery below ~3.6 V where the hard reset lived. Full
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

  defp target_children(_target) do
    [
      button_spec(:button_1),
      button_spec(:button_2),
      NameBadge.Diagnostics,
      NameBadge.Battery,
      NameBadge.PowerMonitor,
      # EInk singleton (configured via `config :eink`) must start before Display,
      # which draws the boot frame through it.
      EInk,
      NameBadge.Display,
      NameBadge.TimezoneService,
      {Task.Supervisor, name: NameBadge.TaskSupervisor},
      NameBadge.Spotify.Tokens,
      NameBadge.Spotify.Library,
      NameBadge.Spotify.ArtCache,
      NameBadge.ScreenManager
    ]
  end

  defp button_spec(button_name, opts \\ []) do
    spec = {NameBadge.ButtonMonitor, Keyword.put(opts, :button, button_name)}
    Supervisor.child_spec(spec, id: button_name)
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
