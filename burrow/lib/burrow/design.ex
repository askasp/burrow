defmodule Burrow.Design do
  @moduledoc """
  A project's boards: HTML files under `design/`, next to the code, which the
  agent draws and the workspace shows in its Design view
  (`BurrowWeb.DesignController` serves them). A chat sees main's boards with
  its own changes, from its checkout; a chat that hasn't started sees main's.

  A change that only touches `design/` is design only: it lands without the
  checks and never ships (`Burrow.Ship`).
  """

  alias Burrow.{Chat, Projects, Workspace}
  alias Totem.Repo

  @dir "design/"
  @draw_tools ~w(edit write patch apply_patch multiedit)

  @doc "Whether `path` (in the app) is under design/."
  def path?(path), do: String.starts_with?(path, @dir)

  @doc "Whether a change's files (`{path, _}`) are all under design/; none is not."
  def only?([]), do: false
  def only?(files), do: Enum.all?(files, fn {path, _} -> path?(path) end)

  @doc """
  The boards chat `chat_id` sees: `%{path, folder, name, title, hash, here?}`
  by folder and name. `path` is the board's in the app, `folder` its folder
  in design/ (`"settings/"`, `""` at the top), `title` its `<title>`, and
  `here?` says the chat changed it.
  """
  def boards(project, chat_id) do
    {files, base} = boards_of(project, chat_id)

    files
    |> Enum.map(fn {path, content} ->
      rel = String.replace_prefix(path, @dir, "")
      hash = Totem.Blob.hash(content)

      %{
        path: path,
        folder: if(Path.dirname(rel) == ".", do: "", else: Path.dirname(rel) <> "/"),
        name: Path.basename(rel),
        title: title(content),
        hash: hash,
        here?: base != nil and base[path] != hash
      }
    end)
    |> Enum.sort_by(&{&1.folder, &1.name})
  end

  # The boards' contents, and the tree the chat's checkout was made from.
  defp boards_of(project, chat_id) do
    dir = Chat.workspace_dir(project, chat_id)

    cond do
      Projects.Project.repo?(project) ->
        {[], nil}

      Workspace.checked_out?(dir) ->
        files =
          for file <- Path.wildcard(Path.join([dir, @dir, "**", "*.{html,htm}"])),
              path <- [Path.relative_to(file, dir)],
              plain?(dir, path),
              do: {path, File.read!(file)}

        {files, Workspace.base_tree(dir)}

      true ->
        repo = Projects.repo_dir(project)

        files =
          for {path, hash} <- Repo.tree(repo),
              path?(path) and Path.extname(path) in ~w(.html .htm),
              do: {path, Repo.blob(repo, hash)}

        {files, nil}
    end
  end

  @doc "A file under design/ as chat `chat_id` sees it, by its path in design/."
  def read(project, chat_id, rel) do
    dir = Chat.workspace_dir(project, chat_id)

    case Path.safe_relative(rel) do
      {:ok, rel} ->
        path = @dir <> rel

        cond do
          not Workspace.checked_out?(dir) -> Repo.file(Projects.repo_dir(project), path)
          plain?(dir, path) -> File.read(Path.join(dir, path))
          true -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  # No links on the way: the agent could point one anywhere on this machine.
  defp plain?(dir, path) do
    segments = Path.split(path)
    last = length(segments)

    Enum.reduce_while(1..last, false, fn n, _ ->
      case File.lstat(Path.join([dir | Enum.take(segments, n)])) do
        {:ok, %{type: :directory}} when n < last -> {:cont, false}
        {:ok, %{type: :regular}} when n == last -> {:halt, true}
        _ -> {:halt, false}
      end
    end)
  end

  defp title(content) do
    case Regex.run(~r{<title[^>]*>\s*([^<]*?)\s*</title>}i, content) do
      [_, title] -> String.slice(title, 0, 60)
      nil -> ""
    end
  end

  @doc """
  What chat `chat_id` changed: `{:design, count}` when that is only boards
  (what Submit design lands), `:code` when it is more, `:none` when nothing.
  """
  def pending(project, chat_id) do
    dir = Chat.workspace_dir(project, chat_id)

    with false <- Projects.Project.repo?(project),
         true <- Workspace.checked_out?(dir),
         {_base, [_ | _] = files} <- Workspace.changes(dir) do
      if only?(files), do: {:design, length(files)}, else: :code
    else
      _ -> :none
    end
  end

  @doc "The design/ files a tool line of the chat (`Burrow.Chat.normalize/1`) draws."
  def drawn(text) do
    case String.split(text, " ", parts: 2) do
      [tool, rest] when tool in @draw_tools ->
        for [_, path] <- Regex.scan(~r{(?:\A|\s|/app/)(design/\S+)}, rest), do: path

      _ ->
        []
    end
  end
end
