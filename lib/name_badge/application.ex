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
