defmodule Totem.Commands do
  @moduledoc """
  What Totem answers, as JSON-ready maps: the same for `Totem.Link` (a
  server Totem dials, such as Burrow), `Totem.Plug` (HTTP) and `Totem.MCP`.

  File contents travel as `"content"` (UTF-8 text) or `"content_base64"`
  (anything else). A file to apply names the hash it must have now
  (`"from"`, null when it must not exist) and is one of:

      {"path": "lib/a.ex", "from": "<sha256>", "content": "..."}
      {"path": "priv/logo.png", "from": null, "content_base64": "..."}
      {"path": "lib/a.ex", "from": "<sha256>", "blob": "<sha256>"}   sent earlier with "blobs"
      {"path": "lib/old.ex", "from": "<sha256>", "deleted": true}

  A draft's files (origin only) are the same without `"from"`.

  `run/2` returns `{:ok, result}` or `{:error, %{"error" => code, ...}}`.
  """

  alias Totem.{Glob, Monitor, Origin, Repo}

  @origin ~w(log tree refs blob draft draft_write draft_check land revert)

  @doc "Runs command `cmd` with JSON arguments `args`."
  @spec run(String.t(), map()) :: {:ok, term()} | {:error, map()}
  def run(cmd, args \\ %{})

  def run(cmd, args) when cmd in @origin do
    if Origin.enabled?(), do: origin(cmd, args), else: {:error, %{"error" => "no_origin"}}
  end

  def run("current", _args) do
    %{tree: tree, hash: hash, label: label} = Totem.current()
    {:ok, %{"tree" => tree, "hash" => hash, "label" => label}}
  end

  def run("read", %{"path" => path}) do
    case Totem.read(path) do
      {:ok, content} -> {:ok, Map.put(content(content), "path", path)}
      :error -> {:error, %{"error" => "not_found", "path" => path}}
    end
  end

  def run("list", args) do
    paths = Totem.current().tree |> Map.keys() |> Enum.sort()

    {:ok,
     if(glob = args["glob"], do: Enum.filter(paths, &Glob.matches?(&1, [glob])), else: paths)}
  end

  def run("search", %{"pattern" => pattern} = args) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {:ok, search(regex, args["glob"], int(args["limit"], 200))}

      {:error, {reason, _}} ->
        {:error, %{"error" => "bad_pattern", "reason" => to_string(reason)}}
    end
  end

  def run("missing", %{"hashes" => hashes}) when is_list(hashes),
    do: {:ok, %{"missing" => Totem.missing(hashes)}}

  def run("blobs", %{"contents" => contents}) when is_list(contents) do
    with {:ok, binaries} <- decode_all(contents),
         do: {:ok, %{"hashes" => Totem.put_blobs(binaries)}}
  end

  def run("apply", %{"files" => files} = args) when is_list(files) do
    with {:ok, files} <- decode_files(files, true) do
      Totem.apply(files, apply_opts(args)) |> result()
    end
  end

  def run("stats", _args), do: {:ok, Monitor.stats()}

  def run("processes", args),
    do: {:ok, Monitor.processes(args["sort"] || "memory", int(args["limit"], 15))}

  def run("errors", _args), do: {:ok, Monitor.errors()}

  def run(cmd, _args), do: {:error, %{"error" => "unknown_command", "command" => cmd}}

  ## Origin

  defp origin("log", args),
    do:
      {:ok,
       Origin.head() && Repo.log(Origin.dir(), int(args["limit"], 50)) |> Enum.map(&change/1)}

  defp origin("tree", args) do
    head = Origin.head()
    at = int(args["at"], head)

    case Repo.change(Origin.dir(), at) do
      nil ->
        {:error, %{"error" => "not_found"}}

      change ->
        {:ok, %{"id" => change.id, "tree" => change.tree, "hash" => Totem.Tree.hash(change.tree)}}
    end
  end

  defp origin("refs", _args) do
    Origin.head()
    {:ok, Repo.refs(Origin.dir())}
  end

  defp origin("blob", %{"hash" => hash}) do
    case Repo.blob(Origin.dir(), hash) do
      nil -> {:error, %{"error" => "not_found"}}
      content -> {:ok, content(content)}
    end
  end

  defp origin("draft", %{"id" => id}) do
    case Repo.draft(Origin.dir(), id) do
      nil -> {:error, %{"error" => "not_found"}}
      draft -> {:ok, draft(draft)}
    end
  end

  defp origin("draft_write", %{"id" => id, "files" => files} = args) when is_list(files) do
    with {:ok, files} <- decode_files(files, false) do
      files = for {path, nil, to} <- files, do: {path, to}

      case Origin.write_draft(id, int(args["base"], nil), files, args["intent"] || "") do
        {:ok, draft} -> {:ok, draft(draft)}
        error -> result(error)
      end
    end
  end

  defp origin("draft_check", %{"id" => id}) do
    case Origin.check(id) do
      {:ok, output} ->
        {:ok, %{"status" => "passed", "output" => trim(output)}}

      {:error, output} when is_binary(output) ->
        {:error, %{"error" => "check_failed", "output" => trim(output)}}

      error ->
        result(error)
    end
  end

  defp origin("land", %{"id" => id} = args), do: Origin.land(id, apply_opts(args)) |> result()

  defp origin("revert", %{"change" => id} = args),
    do: Origin.revert(id, apply_opts(args)) |> result()

  defp origin(cmd, _args), do: {:error, %{"error" => "bad_arguments", "command" => cmd}}

  ## Helpers

  @doc "A file's content as JSON: text when it is UTF-8, base64 otherwise."
  def content(binary) do
    if String.valid?(binary),
      do: %{"content" => binary},
      else: %{"content_base64" => Base.encode64(binary)}
  end

  defp apply_opts(args) do
    Keyword.reject([label: args["label"], watch: args["watch"]], fn {_, v} -> is_nil(v) end)
  end

  defp result({:ok, result}), do: {:ok, Map.new(result, fn {k, v} -> {to_string(k), v} end)}

  defp result({:error, {:conflict, paths}}),
    do: {:error, %{"error" => "conflict", "paths" => paths}}

  defp result({:error, {:load_failed, mode, output}}),
    do: {:error, %{"error" => "load_failed", "mode" => mode, "output" => trim(output)}}

  defp result({:error, {:reverted, mode, errors}}),
    do: {:error, %{"error" => "reverted", "mode" => mode, "errors" => errors}}

  defp result({:error, {:policy, violations}}),
    do: {:error, %{"error" => "policy", "reasons" => Enum.map(violations, & &1.reason)}}

  defp result({:error, {reason, detail}}),
    do: {:error, %{"error" => to_string(reason), "detail" => inspect(detail)}}

  defp result({:error, reason}), do: {:error, %{"error" => to_string(reason)}}

  defp change(change) do
    %{
      "id" => change.id,
      "intent" => change.intent,
      "author" => change.author,
      "at" => change.at,
      "files" => Enum.map(change.files, &elem(&1, 0))
    }
  end

  defp draft(draft) do
    %{
      "id" => draft.id,
      "base" => draft.base,
      "intent" => draft.intent,
      "status" => draft.status,
      "change" => draft.change,
      "files" => Enum.map(draft.files, &elem(&1, 0))
    }
  end

  defp trim(output), do: String.slice(output, -6000, 6000)

  # Query strings bring numbers as text.
  defp int(nil, default), do: default
  defp int(n, _default) when is_integer(n), do: n

  defp int(text, default) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> default
    end
  end

  # {path, from, to}; `from` only where a file applies to what is on disk.
  defp decode_files(files, from?) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case decode_file(file) do
        {:ok, path, to} -> {:cont, {:ok, [{path, if(from?, do: file["from"]), to} | acc]}}
        :error -> {:halt, {:error, %{"error" => "bad_file", "path" => file["path"]}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp decode_file(%{"path" => path, "deleted" => true}) when is_binary(path),
    do: {:ok, path, :deleted}

  defp decode_file(%{"path" => path, "blob" => hash}) when is_binary(path),
    do: {:ok, path, {:blob, hash}}

  defp decode_file(%{"path" => path} = file) when is_binary(path) do
    case decode(file) do
      {:ok, content} -> {:ok, path, content}
      :error -> :error
    end
  end

  defp decode_file(_file), do: :error

  defp decode_all(contents) do
    Enum.reduce_while(contents, {:ok, []}, fn item, {:ok, acc} ->
      case decode(item) do
        {:ok, binary} -> {:cont, {:ok, [binary | acc]}}
        :error -> {:halt, {:error, %{"error" => "bad_content"}}}
      end
    end)
    |> case do
      {:ok, binaries} -> {:ok, Enum.reverse(binaries)}
      error -> error
    end
  end

  defp decode(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp decode(%{"content_base64" => data}) when is_binary(data), do: Base.decode64(data)
  defp decode(_), do: :error

  defp search(regex, glob, limit) do
    root = Totem.info().root

    Totem.current().tree
    |> Enum.sort()
    |> Stream.filter(fn {path, _} -> is_nil(glob) or Glob.matches?(path, [glob]) end)
    |> Stream.flat_map(fn {path, _hash} ->
      case File.read(Path.join(root, path)) do
        {:ok, content} -> if String.valid?(content), do: matches(path, content, regex), else: []
        {:error, _} -> []
      end
    end)
    |> Enum.take(limit)
  end

  defp matches(path, content, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      if Regex.match?(regex, line), do: [%{"path" => path, "line" => n, "text" => line}], else: []
    end)
  end
end
