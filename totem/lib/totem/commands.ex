defmodule Totem.Commands do
  @moduledoc """
  What Totem answers, as JSON-ready maps: the same for `Totem.Link` (a
  server Totem dials, such as Peon), `Totem.Plug` (HTTP) and `Totem.MCP`.

  File contents travel as `"content"` (UTF-8 text) or `"content_base64"`
  (anything else). In a change, a file is one of:

      {"path": "lib/a.ex", "content": "..."}
      {"path": "priv/logo.png", "content_base64": "..."}
      {"path": "lib/a.ex", "blob": "<sha256>"}     sent earlier with "blobs"
      {"path": "lib/old.ex", "deleted": true}

  `run/2` returns `{:ok, result}` or `{:error, %{"error" => code, ...}}`.
  """

  alias Totem.{Glob, Monitor}

  @doc "Runs command `cmd` with JSON arguments `args`."
  @spec run(String.t(), map()) :: {:ok, term()} | {:error, map()}
  def run(cmd, args \\ %{})

  def run("current", _args), do: {:ok, version(Totem.current())}

  def run("versions", args) do
    limit = int(args["limit"], 50)
    {:ok, Totem.versions() |> Enum.take(limit) |> Enum.map(&Map.delete(version(&1), "tree"))}
  end

  def run("read", %{"path" => path}) do
    case Totem.read(path) do
      {:ok, content} -> {:ok, Map.put(content(content), "path", path)}
      :error -> {:error, %{"error" => "not_found", "path" => path}}
    end
  end

  def run("list", args) do
    glob = args["glob"]
    paths = Totem.current().tree |> Map.keys() |> Enum.sort()
    {:ok, if(glob, do: Enum.filter(paths, &Glob.matches?(&1, [glob])), else: paths)}
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
    with {:ok, binaries} <- decode_all(contents) do
      {:ok, %{"hashes" => Totem.put_blobs(binaries)}}
    end
  end

  def run("apply", %{"base" => base, "files" => files} = args) when is_list(files) do
    with {:ok, files} <- decode_files(files) do
      Totem.apply(%{base: base, files: files}, source: args["source"]) |> result()
    end
  end

  def run("rollback", %{"version" => n} = args),
    do:
      Totem.rollback(n, Keyword.reject([source: args["source"]], &is_nil(elem(&1, 1))))
      |> result()

  def run("stats", _args), do: {:ok, Monitor.stats()}

  def run("processes", args),
    do: {:ok, Monitor.processes(args["sort"] || "memory", int(args["limit"], 15))}

  def run("errors", _args), do: {:ok, Monitor.errors()}

  def run(cmd, _args), do: {:error, %{"error" => "unknown_command", "command" => cmd}}

  @doc "A version as JSON."
  def version(v) do
    %{
      "version" => v.version,
      "parent" => v.parent,
      "tree" => v.tree,
      "mode" => v.mode,
      "source" => v.source,
      "status" => v.status,
      "at" => v.at
    }
  end

  @doc "A file's content as JSON: text when it is UTF-8, base64 otherwise."
  def content(binary) do
    if String.valid?(binary),
      do: %{"content" => binary},
      else: %{"content_base64" => Base.encode64(binary)}
  end

  # Query strings bring numbers as text.
  defp int(nil, default), do: default
  defp int(n, _default) when is_integer(n), do: n

  defp int(text, default) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp result({:ok, result}), do: {:ok, stringify(result)}

  defp result({:error, {:conflict, current}}),
    do: {:error, %{"error" => "conflict", "current" => current}}

  defp result({:error, {:load_failed, mode, output}}),
    do: {:error, %{"error" => "load_failed", "mode" => mode, "output" => output}}

  defp result({:error, {reason, detail}}),
    do: {:error, %{"error" => to_string(reason), "detail" => inspect(detail)}}

  defp result({:error, reason}), do: {:error, %{"error" => to_string(reason)}}

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp decode_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case decode_file(file) do
        {:ok, file} -> {:cont, {:ok, [file | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp decode_file(%{"path" => path, "deleted" => true}), do: {:ok, {path, :deleted}}
  defp decode_file(%{"path" => path, "blob" => hash}), do: {:ok, {path, {:blob, hash}}}

  defp decode_file(%{"path" => path} = file) do
    case decode(file) do
      {:ok, content} -> {:ok, {path, content}}
      :error -> {:error, %{"error" => "bad_file", "path" => path}}
    end
  end

  defp decode_file(_file), do: {:error, %{"error" => "bad_file"}}

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
    %{tree: tree} = Totem.current()

    tree
    |> Enum.sort()
    |> Stream.filter(fn {path, _} -> is_nil(glob) or Glob.matches?(path, [glob]) end)
    |> Stream.flat_map(fn {path, hash} ->
      case Totem.blob(hash) do
        {:ok, content} -> if String.valid?(content), do: matches(path, content, regex), else: []
        :error -> []
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
