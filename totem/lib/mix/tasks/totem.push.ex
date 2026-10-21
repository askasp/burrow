defmodule Mix.Tasks.Totem.Push do
  @shortdoc "Lands local changes on a running app that is its own origin"
  @moduledoc """
      TOTEM_TOKEN=... mix totem.push [--intent "what changed"]

  Sends the files changed since the checkout as a draft, has the app build
  and test it, and lands it: the app merges it onto main and loads it. A
  change to the same lines as one since the checkout comes back as a
  conflict: clone again and redo it.
  """
  use Mix.Task

  alias Totem.{Remote, Tree}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [intent: :string])
    %{"url" => url, "base" => base, "tree" => before} = Remote.read!(".")
    {tree, blobs} = Remote.local(".")

    case Tree.changes(before, tree) do
      [] -> Mix.shell().info("Nothing to push")
      changes -> push(url, base, tree, blobs, changes, opts[:intent] || "mix totem.push")
    end
  end

  defp push(url, base, tree, blobs, changes, intent) do
    id = "push-#{System.unique_integer([:positive])}"

    files =
      for {path, hash} <- changes do
        if hash == :deleted,
          do: %{"path" => path, "deleted" => true},
          else: Map.put(Totem.Commands.content(Map.fetch!(blobs, hash)), "path", path)
      end

    draft = %{"id" => id, "base" => base, "intent" => intent, "files" => files}

    with {200, _} <- Remote.post!(url, "/drafts", draft),
         {200, _} <- Remote.post!(url, "/check", %{"id" => id}),
         {200, %{"change" => change, "mode" => mode}} <- Remote.post!(url, "/land", %{"id" => id}) do
      Remote.write!(".", url, change, tree)
      Mix.shell().info("Landed as ##{change}: #{length(changes)} files, loaded #{mode}")
    else
      {_status, %{"error" => "conflict", "paths" => paths}} ->
        Mix.raise(
          "The app changed the same lines in #{Enum.join(paths, ", ")}: clone again and redo them"
        )

      {_status, %{"output" => output} = error} ->
        Mix.raise("#{error["error"]}:\n\n#{output}")

      {status, error} ->
        Mix.raise("#{status}: #{inspect(error)}")
    end
  end
end
