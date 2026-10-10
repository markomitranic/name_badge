defmodule NameBadge.MixProject do
  use Mix.Project

  @app :name_badge
  @name "goatmire"
  @version "0.3.1"
  @all_targets [:trellis]

  def project do
    [
      name: @name,
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {NameBadge.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},
      {:dither, "~> 0.2.4", override: true},
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:circuits_spi, "~> 2.0", targets: @all_targets},
      {:circuits_gpio, "~> 2.1.3", targets: @all_targets},
      # Grayscale-capable eink: upstream `feat/drawing-pipeline` + our single
      # calibrated UC8276 4-gray waveform patch on top (branch
      # `grayscale-on-dp`). Upstream still ships grayscale as an empty stub, so
      # the fork can't be dropped yet; swap back to hex once upstream cuts a
      # release with a real grayscale LUT. For live LUT tuning use the local
      # ../eink clone instead.
      {:eink, github: "markomitranic/eink", branch: "grayscale-on-dp", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_trellis, "~> 0.3.0", runtime: false, targets: :trellis}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
