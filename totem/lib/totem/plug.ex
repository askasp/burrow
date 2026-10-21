if Code.ensure_loaded?(Plug.Conn) do
  defmodule Totem.Plug do
    @moduledoc """
    Totem over HTTP, for apps that have Plug: one line in the endpoint,
    before `Plug.Parsers`,

        plug Totem.Plug

    serves `/_totem/...` (`at: "/other"` to move it), and only with a token:
    `config :totem, token: ...` or `TOTEM_TOKEN`, sent as
    `authorization: Bearer <token>`. Without one it serves nothing.

        GET  /_totem/current            the files' tree, its hash, the last change's label
        GET  /_totem/files/<path>       a file's content
        GET  /_totem/archive            the files as .tar.gz
        GET  /_totem/list | stats | processes | errors
        POST /_totem/missing | blobs | apply | search | read   (JSON, `Totem.Commands`)
        POST /_totem/mcp                MCP (`Totem.MCP`)

    A node that is its own origin (`Totem.Origin`) also serves its history:

        GET  /_totem/log | refs | tree?at=N | blobs/<hash>
        POST /_totem/drafts | check | land | revert
    """

    @behaviour Plug

    import Plug.Conn

    alias Totem.{Commands, MCP}

    @impl true
    def init(opts), do: Keyword.get(opts, :at, "/_totem") |> String.split("/", trim: true)

    @impl true
    def call(conn, prefix) do
      case split(conn.path_info, prefix) do
        {:ok, rest} -> conn |> serve(rest) |> halt()
        :error -> conn
      end
    end

    defp split(path, prefix) do
      if List.starts_with?(path, prefix),
        do: {:ok, Enum.drop(path, length(prefix))},
        else: :error
    end

    defp serve(conn, rest) do
      case token() do
        nil ->
          send_resp(conn, 404, "")

        token ->
          if authorized?(conn, token),
            do: route(conn, conn.method, rest),
            else: json(conn, 401, %{"error" => "unauthorized"})
      end
    end

    defp token, do: Application.get_env(:totem, :token) || System.get_env("TOTEM_TOKEN")

    defp authorized?(conn, token) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> given] -> Plug.Crypto.secure_compare(given, token)
        _ -> false
      end
    end

    defp route(conn, "GET", ["files" | path]) do
      case Totem.read(Enum.join(path, "/")) do
        {:ok, content} ->
          conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, content)

        :error ->
          json(conn, 404, %{"error" => "not_found"})
      end
    end

    defp route(conn, "GET", ["archive"]) do
      conn
      |> put_resp_content_type("application/gzip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="code.tar.gz"))
      |> send_resp(200, Totem.archive())
    end

    defp route(conn, "GET", ["blobs", hash]) do
      case Commands.run("blob", %{"hash" => hash}) do
        {:ok, file} -> json(conn, 200, file)
        {:error, error} -> json(conn, 404, error)
      end
    end

    defp route(conn, "GET", [cmd])
         when cmd in ~w(current stats processes errors list log refs tree),
         do: command(conn, cmd, conn |> fetch_query_params() |> Map.get(:query_params))

    defp route(conn, "POST", ["mcp"]) do
      with {:ok, body, conn} <- body(conn) do
        case body do
          batch when is_list(batch) ->
            case batch |> Enum.map(&MCP.handle/1) |> Enum.reject(&is_nil/1) do
              [] -> send_resp(conn, 202, "")
              responses -> json(conn, 200, responses)
            end

          request ->
            case MCP.handle(request) do
              nil -> send_resp(conn, 202, "")
              response -> json(conn, 200, response)
            end
        end
      end
    end

    @posts %{
      "drafts" => "draft_write",
      "check" => "draft_check",
      "land" => "land",
      "revert" => "revert"
    }

    defp route(conn, "POST", [cmd])
         when cmd in ~w(missing blobs apply search read drafts check land revert) do
      with {:ok, body, conn} <- body(conn), do: command(conn, Map.get(@posts, cmd, cmd), body)
    end

    defp route(conn, _method, _path), do: json(conn, 404, %{"error" => "not_found"})

    defp command(conn, cmd, args) do
      case Commands.run(cmd, args) do
        {:ok, result} ->
          json(conn, 200, result)

        {:error, %{"error" => "conflict"} = error} ->
          json(conn, 409, error)

        {:error, %{"error" => e} = error} when e in ~w(load_failed reverted check_failed) ->
          json(conn, 422, error)

        {:error, %{"error" => e} = error} when e in ~w(not_found no_origin) ->
          json(conn, 404, error)

        {:error, error} ->
          json(conn, 400, error)
      end
    end

    # After Plug.Parsers the body is read already; a JSON array is under "_json".
    defp body(%{body_params: %{"_json" => list}} = conn) when is_list(list),
      do: {:ok, list, conn}

    defp body(%{body_params: %Plug.Conn.Unfetched{}} = conn), do: read(conn, [])

    defp body(%{body_params: params} = conn) when map_size(params) > 0,
      do: {:ok, params, conn}

    defp body(conn), do: read(conn, [])

    defp read(conn, acc) do
      case read_body(conn, length: 64_000_000) do
        {:ok, data, conn} ->
          case JSON.decode(IO.iodata_to_binary([acc, data])) do
            {:ok, body} -> {:ok, body, conn}
            {:error, _} -> json(conn, 400, %{"error" => "bad_json"})
          end

        {:more, data, conn} ->
          read(conn, [acc, data])

        {:error, _} ->
          json(conn, 400, %{"error" => "bad_body"})
      end
    end

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
    end
  end
end
