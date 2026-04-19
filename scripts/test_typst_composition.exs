#!/usr/bin/env elixir
# Quick smoke test for the Spotify screen's cassette-spine Typst template.
# Writes /tmp/spotify_composition_test.png — open it to visually verify.
#
# Run: MIX_TARGET=host mix run scripts/test_typst_composition.exs

tmp_root = Path.join(System.tmp_dir!(), "name_badge_spotify")
File.mkdir_p!(tmp_root)

# Copy a test image into tmp_root
test_image = Path.join(tmp_root, "test_album.png")

unless File.exists?(test_image) do
  IO.puts("Copying placeholder test image...")
  System.cmd("curl", ["-sL", "https://placehold.co/300x300.png", "-o", test_image])
end

artist = "Miles Davis"
album = "Kind of Blue"
filename = Path.basename(test_image)

escape = fn
  nil -> ""
  s when is_binary(s) ->
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("#", "\\#")
    |> String.replace("$", "\\$")
    |> String.replace("*", "\\*")
    |> String.replace("_", "\\_")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("<", "\\<")
    |> String.replace(">", "\\>")
    |> String.replace("@", "\\@")
    |> String.replace("=", "\\=")
    |> String.replace("`", "\\`")
    |> String.replace("\"", "\\\"")
end

template = """
#set page(width: 400pt, height: 300pt, margin: 0pt)
#set text(font: "Poppins")

#grid(
  columns: (300pt, 1pt, 99pt),
  rows: (300pt,),
  image("#{filename}", width: 300pt, height: 300pt, fit: "cover"),
  rect(width: 1pt, height: 300pt, fill: black),
  align(center + horizon, rotate(-90deg, reflow: true,
    box(width: 280pt, inset: (x: 8pt))[
      #align(center, stack(dir: ttb, spacing: 6pt,
        text(size: 18pt, weight: "bold", tracking: 0.5pt)[#{escape.(artist)}],
        text(size: 11pt, style: "italic", fill: rgb("#333333"))[#{escape.(album)}],
      ))
    ]
  ))
)
"""

fonts_dir = Application.app_dir(:name_badge, "priv/typst/fonts")
typst_opts = [root_dir: tmp_root, extra_fonts: [fonts_dir]]

IO.puts("Rendering Typst template...")
IO.puts("Template:\n#{template}")

png =
  Typst.render_to_png!(template, [], typst_opts)
  |> List.first()

out = "/tmp/spotify_composition_test.png"
File.write!(out, png)
IO.puts("\nOK — wrote #{byte_size(png)} bytes to #{out}")
IO.puts("Open with: open #{out}")
