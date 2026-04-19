defmodule NameBadge.Spotify.Album do
  @moduledoc "A single saved album in the user's Spotify library."

  @enforce_keys [:name, :artist, :image_url]
  defstruct [:name, :artist, :image_url]

  @type t :: %__MODULE__{
          name: String.t(),
          artist: String.t(),
          image_url: String.t()
        }
end
