defmodule Mix.Tasks.Totem.Clone do
  @shortdoc "Checks out a running app's code"
  @moduledoc """
      TOTEM_TOKEN=... mix totem.clone https://app.example.com/_totem [dir]

  Writes the version the app runs into `dir` (default: the app's host name)
  and remembers it, so `mix totem.push` sends only what changed.
  """
  use Mix.Task

  alias Totem.Remote

  @impl true
  def run([url | rest]) do
    url = String.trim_trailing(url, "/")
    dir = List.first(rest) || URI.parse(url).host
    if File.exists?(dir) and File.ls!(dir) != [], do: Mix.raise("#{dir} is not empty")

    {200, current} = Remote.get!(url, "/current")
    {200, archive} = Remote.get!(url, "/archive")
    File.mkdir_p!(dir)
    :ok = :erl_tar.extract({:binary, archive}, [:compressed, cwd: String.to_charlist(dir)])
    Remote.write!(dir, url, current)

    Mix.shell().info(
      "Checked out version #{current["version"]} (#{map_size(current["tree"])} files) into #{dir}"
    )
  end

  def run(_), do: Mix.raise("Usage: mix totem.clone URL [DIR]")
end
