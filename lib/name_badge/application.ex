defmodule NameBadge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    silence_status_led()
    hold_wifi_off()
    park_second_core()

    # Monitoring is off to spare power and flash writes. Uncomment any of
    # these (and NameBadge.Diagnostics in children/0) to investigate crashes.
    # NameBadge.Diagnostics.attach_disk_logger()
    # NameBadge.Diagnostics.log_boot()

    Supervisor.start_link(children(), strategy: :one_for_one, name: NameBadge.Supervisor)
  end

  defp children() do
    [
      # NameBadge.Diagnostics,
      # EInk singleton, configured via `config :eink`. Display draws through it.
      EInk,
      NameBadge.Display,
      NameBadge.Screen,
      {NameBadge.Button, NameBadge.Screen}
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

  # The badge works fully offline, so the WiFi chip (by far the biggest
  # drain) is never powered. WIFI_EN is active-low for this board's
  # RTL8188FU; driving it high keeps the chip dark and off the USB bus.
  defp hold_wifi_off() do
    _ = Circuits.GPIO.write_one("WIFI_EN", 1)
    :ok
  end

  # A rotation is a file read plus a ~1.3 s panel draw, which one Cortex-A7
  # handles easily. Taking CPU1 offline lets it power down instead of idling;
  # the BEAM drops to one scheduler first so nothing is pinned to it.
  defp park_second_core() do
    _ = :erlang.system_flag(:schedulers_online, 1)
    _ = :erlang.system_flag(:dirty_cpu_schedulers_online, 1)
    _ = File.write("/sys/devices/system/cpu/cpu1/online", "0")
    :ok
  end
end
