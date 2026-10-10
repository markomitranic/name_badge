defmodule NameBadge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    silence_status_led()
    setup_wifi()

    # Monitoring is off to spare power and flash writes. Uncomment any of
    # these (and NameBadge.Diagnostics in children/0) to investigate crashes.
    # NameBadge.Diagnostics.attach_disk_logger()
    # NameBadge.Diagnostics.log_boot()

    Supervisor.start_link(children(), strategy: :one_for_one, name: NameBadge.Supervisor)
  end

  defp children() do
    [
      # NameBadge.Diagnostics,
      NameBadge.PowerMonitor,
      # EInk singleton, configured via `config :eink`. Display draws through it.
      EInk,
      NameBadge.Display,
      {Task.Supervisor, name: NameBadge.TaskSupervisor},
      NameBadge.Spotify.Tokens,
      NameBadge.Spotify.Library,
      NameBadge.Spotify.ArtCache,
      NameBadge.Spotify.Screen,
      {NameBadge.Button, NameBadge.Spotify.Screen}
    ]
  end

  # The kernel blinks the red status LED (PE9) in a heartbeat pattern from
  # boot. It saves ~0.5 mA average on battery and serves no purpose here,
  # so both the trigger and any mid-blink brightness are cleared.
  defp silence_status_led() do
    _ = File.write("/sys/class/leds/red:status/trigger", "none")
    _ = File.write("/sys/class/leds/red:status/brightness", "0")
    :ok
  end

  # First-boot provisioning: WiFi credentials baked in at burn time
  # (config/provisioning.conf) seed VintageNet unless it already has a network.
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
