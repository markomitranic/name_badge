defmodule NameBadge.Network do
  require Logger

  if Mix.target() == :host do
    def wifi_on(), do: :ok
  else
    @doc """
    Powers the WiFi chip back on by restoring the runtime config that
    `wifi_off/0` stashed. No-op when WiFi is already configured. Never
    touches the persisted config — a reboot always comes back online.

    @example `Network.wifi_on() // :ok`
    """
    def wifi_on() do
      case VintageNet.get_configuration("wlan0") do
        %{type: VintageNet.Technology.Null} ->
          case :persistent_term.get({__MODULE__, :wifi_config}, nil) do
            nil ->
              Logger.warning("Network.wifi_on: no stashed wlan0 config to restore")

            config ->
              Logger.info("Network: powering WiFi on")
              VintageNet.configure("wlan0", config, persist: false)
          end

        _already_configured ->
          :ok
      end

      :ok
    end
  end

  if Mix.target() == :host do
    def wifi_off(), do: :ok
  else
    @doc """
    Hard-powers the WiFi chip off (cuts the WIFI_EN line via the VintageNet
    power manager). Stashes the current runtime config so `wifi_on/0` can
    restore it. No-op when WiFi is already off.

    @example `Network.wifi_off() // :ok`
    """
    def wifi_off() do
      config = VintageNet.get_configuration("wlan0")

      unless match?(%{type: VintageNet.Technology.Null}, config) do
        :persistent_term.put({__MODULE__, :wifi_config}, config)
        Logger.info("Network: powering WiFi off")
        VintageNet.deconfigure("wlan0", persist: false)
      end

      :ok
    end
  end

  if Mix.target() == :host do
    def await_internet(_timeout \\ :timer.seconds(60)), do: :ok
  else
    @doc """
    Blocks until wlan0 reaches `:internet`, polling once a second. Returns
    `:ok`, or `{:error, :timeout}` after `timeout` ms.

    @example `Network.await_internet(30_000) // :ok`
    """
    def await_internet(timeout \\ :timer.seconds(60)) do
      poll_internet(System.monotonic_time(:millisecond) + timeout)
    end

    defp poll_internet(deadline) do
      cond do
        VintageNet.get(["interface", "wlan0", "connection"]) == :internet ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, :timeout}

        true ->
          Process.sleep(1_000)
          poll_internet(deadline)
      end
    end
  end

  if Mix.target() == :host do
    def subscribe(_wlan_property) do
      :noop
    end
  else
    def subscribe(wlan_property) do
      VintageNet.subscribe(wlan_property)
    end
  end

  if Mix.target() == :host do
    def connected?(_wlan_property) do
      :noop
    end
  else
    def connected?(wlan_property) do
      VintageNet.get(wlan_property) == :internet
    end
  end

  if Mix.target() == :host do
    def current_ap() do
      "MOCKED"
    end
  else
    def current_ap() do
      case VintageNet.get(["interface", "wlan0", "wifi", "current_ap"]) do
        %{ssid: ssid} -> ssid
        _ -> nil
      end
    end
  end

  if Mix.target() == :host do
    def wlan_ip() do
      "MOCKED"
    end
  else
    def wlan_ip() do
      case VintageNet.get(["interface", "wlan0", "addresses"]) do
        addrs when is_list(addrs) ->
          case Enum.find(addrs, &(&1.family == :inet)) do
            %{address: {a1, a2, a3, a4}} ->
              "#{a1}.#{a2}.#{a3}.#{a4}"

            _other ->
              "Not connected"
          end

        _ ->
          "Not connected"
      end
    end
  end

  if Mix.target() == :host do
    def usb_ip() do
      "MOCKED"
    end
  else
    def usb_ip() do
      case VintageNet.get(["interface", "usb0", "addresses"]) do
        addrs when is_list(addrs) ->
          case Enum.find(addrs, &(&1.family == :inet)) do
            %{address: {a1, a2, a3, a4}} ->
              "#{a1}.#{a2}.#{a3}.#{a4}"

            _other ->
              "Not connected"
          end

        _ ->
          "Not connected"
      end
    end
  end
end
