defmodule Peon.Agent.MCP do
  @moduledoc """
  MCP server (JSON-RPC 2.0 over HTTP) exposing `Peon.Agent.Tools` to a chat's
  opencode agent. Each token is scoped to one chat.
  """

  alias Peon.Agent.Tools

  @salt "peon mcp"
  @protocol_version "2025-06-18"
  @token_max_age 7 * 24 * 3600

  @doc "Where Peon serves MCP (`PeonWeb.MCPPlug`); mounted into agent containers."
  def socket_path, do: Path.join(Application.fetch_env!(:peon, :data_dir), "mcp.sock")

  @doc "Bandit child serving MCP on the Unix socket."
  def child_spec(_opts) do
    File.rm(socket_path())

    Bandit.child_spec(
      plug: PeonWeb.MCPPlug,
      ip: {:local, socket_path()},
      port: 0,
      startup_log: false
    )
  end

  def token(chat_id), do: Phoenix.Token.sign(PeonWeb.Endpoint, @salt, chat_id)

  def verify(token),
    do: Phoenix.Token.verify(PeonWeb.Endpoint, @salt, token, max_age: @token_max_age)

  @doc "Handles one JSON-RPC message. Returns a response map, or nil for notifications."
  def handle(%{"method" => method} = request, chat_id) do
    case call(method, request["params"] || %{}, chat_id) do
      _ when not is_map_key(request, "id") ->
        nil

      {:ok, result} ->
        %{jsonrpc: "2.0", id: request["id"], result: result}

      {:error, code, message} ->
        %{jsonrpc: "2.0", id: request["id"], error: %{code: code, message: message}}
    end
  end

  def handle(request, _chat_id) do
    %{jsonrpc: "2.0", id: request["id"], error: %{code: -32600, message: "invalid request"}}
  end

  defp call("initialize", params, _chat_id) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || @protocol_version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: "peon", version: "0.1.0"}
     }}
  end

  defp call("ping", _params, _chat_id), do: {:ok, %{}}

  defp call("tools/list", _params, _chat_id) do
    tools =
      for spec <- Tools.specs(),
          do: %{name: spec.name, description: spec.description, inputSchema: spec.parameters}

    {:ok, %{tools: tools}}
  end

  defp call("tools/call", %{"name" => name} = params, chat_id) do
    {text, failed?} = Tools.call(name, params["arguments"] || %{}, chat_id)
    {:ok, %{content: [%{type: "text", text: text}], isError: failed?}}
  end

  defp call("notifications/" <> _, _params, _chat_id), do: {:ok, nil}
  defp call(method, _params, _chat_id), do: {:error, -32601, "method not found: #{method}"}
end
