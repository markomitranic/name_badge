# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# set the time zone database
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :name_badge, :timezone, "Europe/Stockholm"

# Spotify — all three env vars must be set for the Spotify screen to light up.
# Obtain via `elixir scripts/spotify_auth.exs` on your laptop; paste into
# .mise.local.toml. If any are missing the screen is gracefully hidden from
# the top-level menu.
config :name_badge, :spotify,
  client_id: System.get_env("SPOTIFY_CLIENT_ID"),
  client_secret: System.get_env("SPOTIFY_CLIENT_SECRET"),
  refresh_token: System.get_env("SPOTIFY_REFRESH_TOKEN")

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware,
  rootfs_overlay: "rootfs_overlay",
  provisioning: "config/provisioning.conf",
  mksquashfs_flags: ["-no-compression", "-no-xattrs", "-quiet"]

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1753482945"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
