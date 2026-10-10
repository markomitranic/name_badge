#!/usr/bin/env elixir
# Mirrors .spotify/rendered/*.png onto the badge's /data/covers over SSH,
# normally across the USB-C cable. Only new or changed frames are sent,
# frames of albums that left the library are deleted, and the badge shows a
# fresh cover when it's done. Run scripts/sync.exs first.
#
#   mise exec -- elixir scripts/push_covers.exs              # wisteria.local
#   mise exec -- elixir scripts/push_covers.exs other.local

defmodule PushCovers do
  @moduledoc "Diffs the rendered library against the badge by MD5 and syncs it over SFTP."

  @rendered Path.expand("../.spotify/rendered", __DIR__)
  @remote_dir "/data/covers"
  @timeout :timer.minutes(2)

  @doc """
  Pushes the library to `host` and reports what changed.

  @example `PushCovers.run("wisteria.local") // :ok`
  """
  def run(host) do
    conn = connect(host)
    local = local_hashes()
    remote = remote_hashes(conn)

    upload = for {name, hash} <- local, remote[name] != hash, do: name
    delete = Map.keys(remote) -- Map.keys(local)

    IO.puts("#{map_size(local)} frames locally, #{map_size(remote)} on the badge")
    IO.puts("#{length(upload)} to upload, #{length(delete)} to delete")

    {:ok, sftp} = :ssh_sftp.start_channel(conn, timeout: @timeout)
    upload_all(sftp, upload)
    Enum.each(delete, &(:ok = :ssh_sftp.delete(sftp, remote_path(&1), @timeout)))

    if upload != [] or delete != [] do
      exec(conn, "NameBadge.Screen.reload()")
      IO.puts("Done, the badge is showing a fresh cover")
    else
      IO.puts("Already up to date")
    end
  end

  defp connect(host) do
    :logger.set_primary_config(:level, :warning)
    _ = :ssh.start()

    {:ok, conn} =
      :ssh.connect(String.to_charlist(host), 22,
        user: ~c"nerves",
        password: ~c"nerves",
        silently_accept_hosts: true,
        save_accepted_host: false,
        user_interaction: false,
        quiet_mode: true,
        connect_timeout: 10_000
      )

    conn
  end

  defp local_hashes do
    Path.join(@rendered, "*.png")
    |> Path.wildcard()
    |> Map.new(fn path ->
      {Path.basename(path), path |> File.read!() |> :erlang.md5() |> Base.encode16()}
    end)
  end

  # Runs on the badge: clears half-finished uploads and prints "name md5" per frame.
  defp remote_hashes(conn) do
    listing = """
    dir = "#{@remote_dir}"
    File.mkdir_p!(dir)
    for f <- File.ls!(dir), String.ends_with?(f, ".part"), do: File.rm(Path.join(dir, f))
    for f <- File.ls!(dir), String.ends_with?(f, ".png"), do: IO.puts(f <> " " <> Base.encode16(:erlang.md5(File.read!(Path.join(dir, f)))))
    """

    Regex.scan(~r/^(\S+\.png) ([0-9A-F]{32})\r?$/m, exec(conn, listing))
    |> Map.new(fn [_, name, hash] -> {name, hash} end)
  end

  # Each frame lands under a temporary name and is renamed into place, so
  # the screen never reads a half-written file.
  defp upload_all(sftp, names) do
    names
    |> Enum.with_index(1)
    |> Enum.each(fn {name, n} ->
      part = remote_path(name <> ".part")
      :ok = :ssh_sftp.write_file(sftp, part, File.read!(Path.join(@rendered, name)), @timeout)
      :ok = :ssh_sftp.rename(sftp, part, remote_path(name), @timeout)
      IO.write("\r  uploaded #{n}/#{length(names)}")
    end)

    if names != [], do: IO.puts("")
  end

  defp remote_path(name), do: String.to_charlist(Path.join(@remote_dir, name))

  defp exec(conn, code) do
    {:ok, channel} = :ssh_connection.session_channel(conn, @timeout)
    :success = :ssh_connection.exec(conn, channel, String.to_charlist(code), @timeout)
    collect_output(conn, channel, "")
  end

  defp collect_output(conn, channel, acc) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        collect_output(conn, channel, acc <> data)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        acc

      {:ssh_cm, ^conn, _other} ->
        collect_output(conn, channel, acc)
    after
      @timeout -> raise "timed out waiting for the badge"
    end
  end
end

PushCovers.run(List.first(System.argv(), "wisteria.local"))
