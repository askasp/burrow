defmodule Mix.Tasks.Totem.Push do
  @shortdoc "Sends local changes to the running app, which loads them"
  @moduledoc """
      TOTEM_TOKEN=... mix totem.push [--source "what changed"]

  Sends the files changed since the checkout's version (only contents the
  app doesn't have yet) and prints how the app loaded them. Refused when
  the app moved on: `mix totem.pull` first.
  """
  use Mix.Task

  alias Totem.{Remote, Tree}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [source: :string])
    remote = Remote.read!(".")
    {tree, blobs} = Remote.local(".")

    case Tree.changes(remote["tree"], tree) do
      [] ->
        Mix.shell().info("Nothing to push: the files match version #{remote["version"]}")

      changes ->
        push(remote, tree, blobs, changes, opts[:source] || "mix totem.push")
    end
  end

  defp push(remote, tree, blobs, changes, source) do
    url = remote["url"]
    hashes = for {_path, hash} <- changes, hash != :deleted, uniq: true, do: hash
    {200, %{"missing" => missing}} = Remote.post!(url, "/missing", %{"hashes" => hashes})
    contents = Enum.map(missing, &Totem.Commands.content(Map.fetch!(blobs, &1)))
    if contents != [], do: {200, _} = Remote.post!(url, "/blobs", %{"contents" => contents})

    files =
      for {path, hash} <- changes,
          do:
            if(hash == :deleted,
              do: %{"path" => path, "deleted" => true},
              else: %{"path" => path, "blob" => hash}
            )

    body = %{"base" => remote["version"], "files" => files, "source" => source}

    case Remote.post!(url, "/apply", body) do
      {200, result} ->
        Remote.write!(".", url, %{"version" => result["version"], "tree" => tree})

        Mix.shell().info(
          "Version #{result["version"]}: #{length(changes)} files, loaded #{result["mode"]}"
        )

      {409, %{"current" => current}} ->
        Mix.raise(
          "The app is at version #{current} now, not #{remote["version"]}: run mix totem.pull, then push again"
        )

      {422, %{"mode" => mode, "output" => output}} ->
        Mix.raise(
          "The app could not load it (#{mode}) and still runs version #{remote["version"]}:\n\n#{output}"
        )

      {status, error} ->
        Mix.raise("#{status}: #{inspect(error)}")
    end
  end
end
