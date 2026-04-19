if Mix.target() == :host do
  defmodule NameBadge.PreviewLive do
    use Phoenix.LiveView
    def mount(_params, _session, socket) do
      NameBadge.DisplayMock.subscribe()
      current_frame =
        NameBadge.DisplayMock.get_current_frame()
        |> frame_to_data_url()
      {:ok, assign(socket, current_frame: current_frame)}
    end
    def render(assigns) do
      ~H"""
      <script src="https://cdn.tailwindcss.com"></script>
      <script>
        tailwind.config = {
          theme: {
            extend: {
              fontFamily: {
                sans: ['Helvetica', 'Arial', 'sans-serif']
              }
            }
          }
        }
      </script>
      <style>
        html, body { color-scheme: light dark; background-color: #f3f4f6; }
        @media (prefers-color-scheme: dark) {
          html, body { background-color: #171717; }
        }
        kbd {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.7rem;
          padding: 0 0.3rem;
          border-radius: 0.25rem;
          border: 1px solid currentColor;
          opacity: 0.6;
          margin-left: 0.4rem;
        }
      </style>
      <div
        phx-window-keydown="key"
        class="bg-gray-100 text-gray-900 dark:bg-neutral-900 dark:text-neutral-100 font-sans flex flex-col justify-center items-center min-h-screen w-full p-8">
        <div class="relative w-full sm:w-3/4 md:w-1/2 max-w-[1200px]">
          <img
            src={@current_frame}
            class="block border border-gray-300 dark:border-neutral-700 rounded aspect-4/3 w-full"
          />
          <div class="hidden dark:block absolute inset-0 rounded bg-black/55 pointer-events-none" aria-hidden="true"></div>
        </div>
        <div class="flex items-center justify-center gap-2 mt-4 w-full sm:w-3/4 md:w-1/2">
          <button
            phx-click="button_1"
            phx-value-press_type="long_press"
            class={button_class()}>
            A (Long)<kbd>1</kbd>
          </button>
          <button
            phx-click="button_1"
            phx-value-press_type="single_press"
            class={button_class()}>
            A<kbd>2</kbd>
          </button>
          <button
            phx-click="button_2"
            phx-value-press_type="single_press"
            class={button_class()}>
            B<kbd>3</kbd>
          </button>
          <button
            phx-click="button_2"
            phx-value-press_type="long_press"
            class={button_class()}>
            B (Long)<kbd>4</kbd>
          </button>
        </div>
      </div>
      """
    end
    def handle_info({:frame, packed_binary}, state) do
      {:noreply, assign(state, :current_frame, frame_to_data_url(packed_binary))}
    end
    def handle_event("button_" <> _rest = button_name, %{"press_type" => press_type}, socket) do
      # technically this is unsafe. But this is only running on your local machine
      NameBadge.ButtonMonitor.send_button_press(
        String.to_atom(button_name),
        String.to_atom(press_type)
      )
      {:noreply, socket}
    end
    def handle_event("key", %{"key" => key}, socket) do
      case key do
        "1" -> NameBadge.ButtonMonitor.send_button_press(:button_1, :long_press)
        "2" -> NameBadge.ButtonMonitor.send_button_press(:button_1, :single_press)
        "3" -> NameBadge.ButtonMonitor.send_button_press(:button_2, :single_press)
        "4" -> NameBadge.ButtonMonitor.send_button_press(:button_2, :long_press)
        _ -> :ok
      end
      {:noreply, socket}
    end
    defp frame_to_data_url(frame) do
      "data:image/png;base64," <> Base.encode64(frame)
    end

    defp button_class() do
      "flex-1 min-w-28 px-4 py-2 border rounded-lg cursor-pointer font-bold transition-all duration-100 ease-in-out " <>
        "border-gray-300 bg-white text-gray-900 hover:bg-gray-50 hover:border-gray-600 active:scale-95 active:bg-gray-200 " <>
        "dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-700 dark:hover:border-neutral-500 dark:active:bg-neutral-600"
    end
  end
end
