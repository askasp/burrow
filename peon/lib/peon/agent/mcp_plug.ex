defmodule Peon.Agent.MCP.Plug do
  @moduledoc """
  MCP (`Peon.Agent.MCP`) over HTTP, served only on the instance's Unix
  socket (`Peon.Agent.MCP.socket_path/0`). Agent containers get the socket
  mounted and reach it through `priv/mcp_bridge.exs`, so no network path
  from the sandbox to Peon is needed.
  """

  # The socket's instance arrives as the plug's options.
  use Plug.Builder, copy_opts_to_assign: :instance

  alias Peon.Agent.MCP

  plug(:put_instance)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 20_000_000)
  plug(:dispatch)

  # Each request runs in its own process, as the socket's instance.
  def put_instance(conn, _opts) do
    Peon.Instance.put(conn.assigns.instance)
    conn
  end

  def dispatch(%{method: "POST"} = conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, chat_id} <- MCP.verify(token) do
      respond(conn, conn.body_params, chat_id)
    else
      _ -> send_json(conn, 401, %{error: "invalid token"})
    end
  end

  def dispatch(conn, _opts), do: send_resp(conn, 405, "")

  # A JSON array (batch) arrives under "_json".
  defp respond(conn, %{"_json" => batch}, chat_id) when is_list(batch) do
    case batch |> Enum.map(&MCP.handle(&1, chat_id)) |> Enum.reject(&is_nil/1) do
      [] -> send_resp(conn, 202, "")
      responses -> send_json(conn, 200, responses)
    end
  end

  defp respond(conn, request, chat_id) do
    case MCP.handle(request, chat_id) do
      nil -> send_resp(conn, 202, "")
      response -> send_json(conn, 200, response)
    end
  end

  defp send_json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
