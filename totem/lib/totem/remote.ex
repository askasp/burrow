defmodule Totem.Remote do
  @moduledoc """
  HTTP to a running app's `Totem.Plug`, for `mix totem.clone`, `mix
  totem.push` and `mix totem.promote`. A checkout remembers its app's URL and
  the change and tree it was made from in `.totem/remote.json`. Tokens come
  from the environment (`TOTEM_TOKEN`), never from a file.
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

  def write!(dir, url, base, tree) do
    path = Path.join(dir, @file_name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"url" => url, "base" => base, "tree" => tree}))
  end

  @doc "The files under `dir` as a tree, with their contents."
  def local(dir), do: Tree.from_dir(dir, Ignore.matcher(dir))

  def get!(url, path, token \\ nil), do: request!(:get, url <> path, nil, token)

  def post!(url, path, body, token \\ nil),
    do: request!(:post, url <> path, JSON.encode!(body), token)

  defp request!(method, url, body, token) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    token =
      token || System.get_env("TOTEM_TOKEN") ||
        Mix.raise("Set TOTEM_TOKEN to the app's Totem token")

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
