import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without real-time clocks.
config :nerves, :erlinit, update_clock: true

# E-ink display (new drawing-pipeline API). Started as a named GenServer from
# the supervision tree; drivers read this app env in EInk.init/1.
config :eink,
  driver: EInk.Driver.UC8276,
  width: 400,
  height: 300,
  driver_config: [
    dc_pin: "EPD_DC",
    reset_pin: "EPD_RESET",
    busy_pin: "EPD_BUSY",
    spi_device: "spidev0.0",
    spi_opts: [speed_hz: 1_000_000],
    debug: false
  ]

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

config :nerves_ssh,
  daemon_option_overrides: [
    {:pwdfun, &NameBadge.ssh_check_pass/2},
    {:auth_method_kb_interactive_data, &NameBadge.ssh_show_prompt/3}
  ]

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  # The watchdog only runs while the chip is powered (the PM state machine is
  # dormant in :off), and is pet whenever connectivity is >= :lan — so it only
  # fires after 10 straight minutes powered-but-disconnected, i.e. a genuinely
  # hung chip on an always-on screen. The 60s default was too impatient: it reset
  # the chip ~70s after boot (10s power-on hold + 60s) when association was slow.
  # Spotify's ~1 min refill bursts never come near 10 min, and each burst is a
  # hard power cycle anyway, so bursts self-heal without the watchdog.
  power_managers: [
    {NameBadge.Wifi, [gpio: "WIFI_EN", ifname: "wlan0", watchdog_timeout: :timer.minutes(10)]}
  ],
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "wisteria"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    }
  ]
