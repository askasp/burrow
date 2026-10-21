defmodule Mix.Tasks.Totem.Clone do
  @shortdoc "Checks out a running app's code"
  @moduledoc """
      TOTEM_TOKEN=... mix totem.clone https://app.example.com/_totem [dir]

  Writes the app's files into `dir` (default: the app's host name) and
  remembers them, so `mix totem.push` sends only what changed. From an app
  that is its own origin, the checkout is of main's latest change.
  """
  use Mix.Task

  alias Totem.Remote

  @impl true
  def run([url | rest]) do
    url = String.trim_trailing(url, "/")
    dir = List.first(rest) || URI.parse(url).host
    if File.exists?(dir) and File.ls!(dir) != [], do: Mix.raise("#{dir} is not empty")

    {base, tree} =
      case Remote.get!(url, "/tree") do
        {200, %{"id" => id, "tree" => tree}} -> {id, tree}
        _ -> {nil, elem(Remote.get!(url, "/current"), 1)["tree"]}
      end

    {200, archive} = Remote.get!(url, "/archive")
    File.mkdir_p!(dir)
    :ok = :erl_tar.extract({:binary, archive}, [:compressed, cwd: String.to_charlist(dir)])
    Remote.write!(dir, url, base, tree)
    at = if base, do: " at ##{base}", else: ""
    Mix.shell().info("Checked out #{map_size(tree)} files#{at} into #{dir}")
  end

  def run(_), do: Mix.raise("Usage: mix totem.clone URL [DIR]")
end
