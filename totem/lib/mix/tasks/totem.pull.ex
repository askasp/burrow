defmodule Mix.Tasks.Totem.Pull do
  @shortdoc "Brings in what changed in the running app since the checkout"
  @moduledoc """
      TOTEM_TOKEN=... mix totem.pull

  Writes the files the app changed since the checkout's version, keeping
  local changes. Stops without writing anything when a file changed on both
  sides, and names it.
  """
  use Mix.Task

  alias Totem.{Remote, Tree}

  @impl true
  def run(_args) do
    remote = Remote.read!(".")
    url = remote["url"]
    {200, current} = Remote.get!(url, "/current")
    {local, _blobs} = Remote.local(".")
    theirs = Tree.changes(remote["tree"], current["tree"])
    mine = Tree.changed_paths(remote["tree"], local)

    clashes =
      for {path, hash} <- theirs,
          MapSet.member?(mine, path),
          Map.get(local, path, :deleted) != hash,
          do: path

    if clashes != [], do: Mix.raise("Changed here and in the app: #{Enum.join(clashes, ", ")}")

    for {path, hash} <- theirs, Map.get(local, path, :deleted) != hash do
      if hash == :deleted do
        File.rm!(path)
      else
        {200, content} = Remote.get!(url, "/files/" <> path)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end
    end

    Remote.write!(".", url, current)

    Mix.shell().info(
      "Up to date with version #{current["version"]} (#{length(theirs)} files changed there)"
    )
  end
end
