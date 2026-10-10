defmodule NameBadge.Display do
  @moduledoc """
  Serializes every draw to the e-ink panel, from a PNG or a Typst template.

  The panel keeps its last image without power, so boot draws nothing:
  whatever cover was showing stays up until the first new one is ready.
  """

  use GenServer

  alias NameBadge.Diagnostics

  # A grayscale draw takes ~1.3 s idle but over 4 s while the Spotify art
  # refill is dithering covers on the other core, and GenServer.call defaults
  # to 5 s. That default used to turn a merely slow draw into a crash that
  # cascaded into a reset loop. A slow panel is normal here, so wait it out.
  @draw_timeout :timer.seconds(30)
  @render_timeout :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Renders a full-page Typst template and draws it.

  `opts` go straight to `EInk.draw/2` (notably `mode: :full | :fast | :grayscale`).
  `anti_ghost: true` flushes the panel white first (~1 extra second) to clear
  residue the previous image left in the grayscale mids.

  @example `Display.render_typst("#set page(width: 400pt, height: 300pt)\\nHi") // :ok`
  """
  def render_typst(markup, opts \\ []) do
    GenServer.call(__MODULE__, {:render_typst, markup, opts}, @render_timeout)
  end

  @doc """
  Draws a PNG binary. `opts` as in `render_typst/2`.

  @example `Display.render_png(png, mode: :grayscale) // :ok`
  """
  def render_png(png, opts \\ []) do
    GenServer.call(__MODULE__, {:render_png, png, opts}, @render_timeout)
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:render_typst, markup, opts}, _from, state) do
    markup
    |> render_template()
    |> draw(opts)

    {:reply, :ok, state}
  end

  def handle_call({:render_png, png, opts}, _from, state) do
    draw(png, opts)
    {:reply, :ok, state}
  end

  # EInk.draw/2 and EInk.clear/2 hardcode the 5 s call default, so the
  # GenServer is addressed directly to get a timeout the panel can meet.
  # EInk treats a raw binary as packed pixels, so PNG bytes are decoded first.
  defp draw(png, opts) do
    image = Dither.decode!(png)
    {anti_ghost?, opts} = Keyword.pop(opts, :anti_ghost, false)

    if anti_ghost? do
      Diagnostics.measure(:display_clear, fn ->
        GenServer.call(EInk, {:clear, :white, opts}, @draw_timeout)
      end)
    end

    Diagnostics.measure(:display_draw, fn ->
      GenServer.call(EInk, {:draw, image, opts}, @draw_timeout)
    end)
  end

  defp render_template(markup) do
    typst_dir = Application.app_dir(:name_badge, "priv/typst")
    typst_opts = [root_dir: typst_dir, extra_fonts: [Path.join(typst_dir, "fonts")]]

    markup
    |> Typst.render_to_png!([], typst_opts)
    |> List.first()
  end
end
