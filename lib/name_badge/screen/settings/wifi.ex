defmodule NameBadge.Screen.Settings.WiFi do
  use NameBadge.Screen

  @impl NameBadge.Screen
  def render(assigns) do
    on? = assigns.wifi_on?

    """
    #pad(x: 16pt)[
      #show heading: set text(font: "Silkscreen", size: 32pt, tracking: -4pt)

      = WiFi Setup

      #let toggle(on) = box(
        width: 56pt, height: 28pt, radius: 14pt, inset: 3pt,
        fill: if on { black } else { white }, stroke: 1.5pt,
        align((if on { right } else { left }) + horizon,
          circle(radius: 11pt, fill: white, stroke: 1pt)))

      #grid(columns: (auto, 1fr), column-gutter: 14pt, align: horizon,
        toggle(#{on?}),
        text(size: 22pt, weight: 600)[WiFi is #{if on?, do: "ON", else: "OFF"}])

      #v(2pt)

      #text(size: 15pt)[
        1. Connect to wifi network #{VintageNetWizard.APMode.ssid()}
        2. Go to http://wifi.config
        3. Enter network credentials
        4. Apply configuration
        5. Long-press B to connect
      ]
    ]
    """
  end

  @impl NameBadge.Screen
  def mount(_args, screen) do
    NameBadge.Network.wifi_on()
    VintageNetWizard.run_wizard()

    screen =
      screen
      |> assign(button_hints: %{a: "Toggle WiFi", b: "Back"})
      |> assign(wifi_on?: NameBadge.Network.wifi_present?())

    {:ok, screen}
  end

  @impl NameBadge.Screen
  def handle_button(:button_1, :single_press, screen) do
    if screen.assigns.wifi_on? do
      NameBadge.Network.wifi_off()
      {:noreply, assign(screen, wifi_on?: false)}
    else
      NameBadge.Network.wifi_on()
      {:noreply, assign(screen, wifi_on?: true)}
    end
  end

  def handle_button(_button, _press_type, screen), do: {:noreply, screen}

  @impl NameBadge.Screen
  def terminate(_reason, screen) do
    VintageNetWizard.stop_wizard()
    screen
  end
end
