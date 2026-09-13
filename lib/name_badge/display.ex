defmodule NameBadge.Display do
  use GenServer

  require Logger

  # A grayscale draw takes ~1.3 s idle but over 4 s while the Spotify art
  # refill is dithering covers on the other core, and GenServer.call defaults
  # to 5 s. That default used to turn a merely slow draw into a crash that
  # cascaded: screen dies, ScreenManager falls back to the menu, the menu's
  # own render hits the same busy panel and dies too, over and over until a
  # hard reset. A slow panel is normal here, so wait it out instead.
  @draw_timeout :timer.seconds(30)
  @render_timeout :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Render a Typst template to the display.

  `opts` are passed straight to `EInk.draw/2` — notably `mode: :full | :fast | :grayscale`.
  `anti_ghost: true` flushes the panel white before the draw (~1 extra second)
  to clear residue the previous image left in the grayscale mids.
  """
  def render_typst(markup, opts \\ []) do
    GenServer.call(__MODULE__, {:render_typst, markup, opts}, @render_timeout)
  end

  @doc """
  Render a PNG (binary or Dither ref) to the display. `opts` forwarded to
  `EInk.draw/2`, except `anti_ghost` (see `render_typst/2`).
  """
  def render_png(png, opts \\ []) do
    GenServer.call(__MODULE__, {:render_png, png, opts}, @render_timeout)
  end

  @impl GenServer
  def init(_opts) do
    # The EInk singleton is started separately (see NameBadge.Application +
    # `config :eink`). Here we just paint the boot frame through it.
    EInk.clear(:white)
    EInk.draw(initial_frame())

    # this sleep blocks the init of other processes in the
    # supervision tree, creating a short "loading screen"
    Process.sleep(3_000)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:render_typst, markup, opts}, _from, state) do
    eval_template(markup)
    |> Dither.decode!()
    |> draw(opts)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:render_png, png, opts}, _from, state) do
    to_dither(png)
    |> draw(opts)

    {:reply, :ok, state}
  end

  # EInk.draw/2 and EInk.clear/2 hardcode the 5 s call default, so the
  # GenServer is addressed directly to get a timeout the panel can meet.
  defp draw(image, opts) do
    {anti_ghost?, opts} = Keyword.pop(opts, :anti_ghost, false)

    if anti_ghost?, do: GenServer.call(EInk, {:clear, :white, opts}, @draw_timeout)
    GenServer.call(EInk, {:draw, image, opts}, @draw_timeout)
  end

  # EInk.draw treats a raw binary as already-packed pixel data, so PNG bytes must
  # be decoded into a %Dither{} first. A Dither ref is already decoded.
  defp to_dither(png) when is_binary(png), do: Dither.decode!(png)
  defp to_dither(ref) when is_reference(ref), do: ref

  defp initial_frame() do
    """
    #set page(width: 400pt, height: 300pt)
    #place(center + horizon, image("images/logos.svg", width: 196pt))
    """
    |> Typst.render_to_png!([], root_dir: Application.app_dir(:name_badge, "priv/typst"))
    |> List.first()
    |> Dither.decode!()
  end

  def eval_template(template) do
    typst_opts = [root_dir: typst_dir(), extra_fonts: [fonts_dir()]]

    Typst.render_to_png!(template, [], typst_opts)
    |> List.first()
  end

  defp typst_dir, do: Application.app_dir(:name_badge, "priv/typst")
  defp fonts_dir, do: Path.join(typst_dir(), "fonts")
end
