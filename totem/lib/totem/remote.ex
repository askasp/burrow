defmodule Totem.Remote do
  @moduledoc """
  A checkout of a running app's code, for `mix totem.clone`, `mix
  totem.push` and `mix totem.pull`: the app's `Totem.Plug` URL and the
  version the files on disk were last in step with, in `.totem/remote.json`.
  The token comes from `TOTEM_TOKEN`, never from a file.
  """

  alias Totem.{Ignore, Tree}

  # From OTP's inets, ssl and public_key, started only for these tasks.
  @compile {:no_warn_undefined, [:httpc, :public_key]}

  @file_name ".totem/remote.json"

  @doc "Reads `.totem/remote.json` under `dir`."
  def read!(dir) do
    case File.read(Path.join(dir, @file_name)) do
      {:ok, json} -> JSON.decode!(json)
      {:error, _} -> Mix.raise("No #{@file_name} here: run mix totem.clone first")
    end
  end

  def write!(dir, url, version) do
    path = Path.join(dir, @file_name)
    File.mkdir_p!(Path.dirname(path))
    data = %{"url" => url, "version" => version["version"], "tree" => version["tree"]}
    File.write!(path, JSON.encode!(data))
  end

  @doc "The files under `dir` as a tree, with their contents."
  def local(dir), do: Tree.from_dir(dir, Ignore.matcher(dir))

  def get!(url, path), do: request!(:get, url <> path, nil)
  def post!(url, path, body), do: request!(:post, url <> path, JSON.encode!(body))

  defp request!(method, url, body) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    token = System.get_env("TOTEM_TOKEN") || Mix.raise("Set TOTEM_TOKEN to the app's Totem token")
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    request =
      if method == :get,
        do: {String.to_charlist(url), headers},
        else: {String.to_charlist(url), headers, ~c"application/json", body}

    http = [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]

    case :httpc.request(method, request, http, body_format: :binary) do
      {:ok, {{_, status, _}, resp_headers, data}} ->
        json? =
          Enum.any?(resp_headers, fn {k, v} ->
            k == ~c"content-type" and to_string(v) =~ "json"
          end)

        {status, if(json?, do: JSON.decode!(data), else: data)}

      {:error, reason} ->
        Mix.raise("#{url}: #{inspect(reason)}")
    end
  end
end
