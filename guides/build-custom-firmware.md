# Build Custom Firmware

This project uses Elixir version 1.18.3 and OTP 27.3.4. Please install these
versions before proceeding. The recommended way to do this is via
[mise](https://mise.jdx.dev/getting-started.html) or `asdf`. After installing
`mise`, you can run `mise install` in the root directory of this repo to install
the required Elixir and Erlang versions.

To build a firmware from source, you also need to
[install Nerves](https://hexdocs.pm/nerves/installation.html), following the
instructions for your machine.

Once everything is installed, in this root directory of the repo, run:

```sh
export MIX_TARGET=trellis
mix deps.get
mix firmware
```

To upload over SSH (device must be reachable on the network):

```sh
cat _build/trellis_dev/nerves/images/name_badge.fw | ssh -s nerves@wisteria.local fwup
```

This requires that the device is already running a valid firmware and is
accessible over your local network.

This means that it is connected to the same WiFi network, or that it is directly
connected to your computer via USB cable.

## Flashing via FEL

If the device is not running a valid firmware or is inaccessible via the
network, you may flash it via FEL mode as described in the
[Flashing via FEL](/guides/flashing-via-fel.md) guide.

After the device connects as a USB storage device, run `mix burn`
