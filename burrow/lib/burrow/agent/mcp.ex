defmodule Burrow.Agent.MCP do
  @moduledoc """
  MCP server (JSON-RPC 2.0 over HTTP) exposing `Burrow.Agent.Tools` to the
  chats' opencode agents, on one Unix socket for every project. Each token
  is scoped to one chat of one project.
  """

  alias Burrow.Agent.Tools

  @salt "peon mcp"
  @protocol_version "2025-06-18"
  @token_max_age 7 * 24 * 3600

  @doc "Where Burrow serves MCP; mounted into agent containers as /peon/mcp.sock."
  def socket_path, do: Path.join(Application.fetch_env!(:burrow, :data_dir), "mcp.sock")

  @doc "Bandit child serving MCP on the socket."
  def child_spec(_opts) do
    File.mkdir_p!(Path.dirname(socket_path()))
    File.rm(socket_path())

    Bandit.child_spec(
      plug: Burrow.Agent.MCP.Plug,
      ip: {:local, socket_path()},
      port: 0,
      startup_log: false
    )
  end

  def token(project_id, chat_id), do: Plug.Crypto.sign(secret(), @salt, {project_id, chat_id})

  def verify(token), do: Plug.Crypto.verify(secret(), @salt, token, max_age: @token_max_age)

  defp secret, do: Application.fetch_env!(:burrow, BurrowWeb.Endpoint)[:secret_key_base]

  @doc "Handles one JSON-RPC message. Returns a response map, or nil for notifications."
  def handle(%{"method" => method} = request, caller) do
    case call(method, request["params"] || %{}, caller) do
      _ when not is_map_key(request, "id") ->
        nil

      {:ok, result} ->
        %{jsonrpc: "2.0", id: request["id"], result: result}

      {:error, code, message} ->
        %{jsonrpc: "2.0", id: request["id"], error: %{code: code, message: message}}
    end
  end

  def handle(request, _caller) do
    %{jsonrpc: "2.0", id: request["id"], error: %{code: -32600, message: "invalid request"}}
  end

  defp call("initialize", params, _caller) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || @protocol_version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: "peon", version: "1.0.0"}
     }}
  end

  defp call("ping", _params, _caller), do: {:ok, %{}}

  defp call("tools/list", _params, {project, _chat_id}) do
    tools =
      for spec <- Tools.specs(project),
          do: %{name: spec.name, description: spec.description, inputSchema: spec.parameters}

    {:ok, %{tools: tools}}
  end

  defp call("tools/call", %{"name" => name} = params, {project, chat_id}) do
    {text, failed?} = Tools.call(name, params["arguments"] || %{}, project, chat_id)
    {:ok, %{content: [%{type: "text", text: text}], isError: failed?}}
  end

  defp call("notifications/" <> _, _params, _caller), do: {:ok, nil}
  defp call(method, _params, _caller), do: {:error, -32601, "method not found: #{method}"}
end
