defmodule NameBadge do
  @moduledoc """
  SSH login hooks for the badge's IEx prompt.
  """

  @doc """
  Checks an SSH password against the configured one (default `nerves`).

  @example `NameBadge.ssh_check_pass(~c"nerves", ~c"nerves") // true`
  """
  def ssh_check_pass(_provided_username, provided_password) do
    correct_password = Application.get_env(:name_badge, :password, "nerves")

    provided_password == to_charlist(correct_password)
  end

  @doc """
  Builds the keyboard-interactive SSH prompt shown before the password.

  @example `NameBadge.ssh_show_prompt(peer, ~c"nerves", ~c"ssh") // {~c"Spotify Badge", ...}`
  """
  def ssh_show_prompt(_peer, _username, _service) do
    {:ok, name} = :inet.gethostname()

    msg = """
    ssh nerves@#{name}.local # Use password "nerves"
    """

    {~c"Spotify Badge", to_charlist(msg), ~c"Password: ", false}
  end
end
