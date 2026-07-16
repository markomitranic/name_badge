#!/usr/bin/env elixir
# Exercises the ArtCache queue logic end-to-end on the host: seeds a full
# batch of fake covers, then drains it with take() and checks the refill
# trigger fires exactly when the count drops below the low-water mark.
#
# Run: SPOTIFY_CLIENT_ID=fake SPOTIFY_CLIENT_SECRET=fake SPOTIFY_REFRESH_TOKEN=fake \
#        MIX_TARGET=host mix run scripts/test_art_cache.exs
#
# The fake credentials make Tokens.configured?() true so maybe_refill/1 runs;
# the spawned refill task then fails against the real Spotify API (bad token)
# which also exercises the failure-cooldown path.

alias NameBadge.Spotify.ArtCache

cache_dir = Path.join(System.tmp_dir!(), "name_badge_spotify_art")
File.mkdir_p!(cache_dir)
File.ls!(cache_dir) |> Enum.each(&File.rm!(Path.join(cache_dir, &1)))

for n <- 1..10 do
  id = "seed_#{String.pad_leading(to_string(n), 2, "0")}"
  File.write!(Path.join(cache_dir, id <> ".png"), "fake png #{n}")
  File.write!(Path.join(cache_dir, id <> ".json"), ~s({"artist":"Artist #{n}","album":"Album #{n}"}))
end

count = fn ->
  cache_dir |> File.ls!() |> Enum.count(&String.ends_with?(&1, ".json"))
end

refill_running? = fn ->
  :sys.get_state(ArtCache).refill_task != nil
end

IO.puts("Seeded #{count.()} covers. Draining...\n")
IO.puts("take | cover        | left | refill in flight?")

failures =
  for n <- 1..11, reduce: [] do
    acc ->
      cover = ArtCache.take()
      label = if cover, do: cover.artist, else: "nil"
      left = count.()
      refilling = refill_running?.()
      IO.puts("#{String.pad_leading(to_string(n), 4)} | #{String.pad_trailing(label, 12)} | #{String.pad_leading(to_string(left), 4)} | #{refilling}")

      checks = [
        {n <= 10 and cover == nil, "take #{n} should have returned a cover"},
        {n == 11 and cover != nil, "take 11 should have found the cache empty"},
        {n < 8 and refilling, "refill must not start while count >= low water (take #{n})"},
        {n == 8 and not refilling, "refill should start on take 8 (count dropped to 2)"}
      ]

      acc ++ for {bad, msg} <- checks, bad, do: msg
  end

state = :sys.get_state(ArtCache)
IO.puts("\nconsumer monitored: #{inspect(state.consumer)} (this script's pid: #{inspect(self())})")

failures =
  if state.consumer == self() do
    failures
  else
    failures ++ ["ArtCache should be monitoring the take() caller"]
  end

if failures == [] do
  IO.puts("\nALL CHECKS PASSED")
  System.halt(0)
else
  IO.puts("\nFAILURES:")
  Enum.each(failures, &IO.puts("  ✗ " <> &1))
  System.halt(1)
end
