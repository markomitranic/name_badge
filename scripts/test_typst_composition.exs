#!/usr/bin/env elixir
# Smoke test for the Spotify screen's cassette-spine template — calls the real
# NameBadge.Screen.Spotify.compose_png/4, including the Japanese font fallback
# and the wifi indicator. Writes /tmp/spotify_composition_test_*.png.
#
# Run: MIX_TARGET=host mix run scripts/test_typst_composition.exs
#
# NOTE: the host typst NIF also loads macOS system fonts, so Japanese rendering
# here does NOT prove it works on the badge (which has no system fonts). It
# proves the template compiles, the fallback chain is valid, and layout/icon
# placement look right. Final glyph verification happens on-device.

tmp_root = Path.join(System.tmp_dir!(), "name_badge_spotify")
File.mkdir_p!(tmp_root)

test_image = Path.join(tmp_root, "test_album.png")

unless File.exists?(test_image) do
  IO.puts("Copying placeholder test image...")
  System.cmd("curl", ["-sL", "https://placehold.co/300x300.png", "-o", test_image])
end

cases = [
  {"latin", "Miles Davis", "Kind of Blue"},
  {"scandinavian", "Bjørn Sæther", "Blåbærsyltetøy på låven"},
  {"japanese", "坂本龍一", "async (アシンク)"}
]

for {name, artist, album} <- cases do
  png = NameBadge.Screen.Spotify.compose_png(test_image, artist, album)
  out = "/tmp/spotify_composition_test_#{name}.png"
  File.write!(out, png)
  IO.puts("OK — #{name}: #{byte_size(png)} bytes → #{out}")
end

System.halt(0)
