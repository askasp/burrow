defmodule Peon.MCPTest do
  use ExUnit.Case, async: true

  alias Peon.Agent.MCP

  test "initialize, tools/list and errors follow JSON-RPC" do
    init =
      MCP.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-06-18"}
        },
        "chat"
      )

    assert %{id: 1, result: %{serverInfo: %{name: "peon"}, protocolVersion: "2025-06-18"}} = init

    assert MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, "chat") ==
             nil

    %{result: %{tools: tools}} =
      MCP.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, "chat")

    assert Enum.map(tools, & &1.name) == [
             "submit_changeset",
             "restart_preview",
             "restore",
             "runtime"
           ]

    assert %{error: %{code: -32601}} =
             MCP.handle(%{"jsonrpc" => "2.0", "id" => 3, "method" => "nope"}, "chat")
  end

  test "tokens are scoped to one chat" do
    assert {:ok, "abc"} = "abc" |> MCP.token() |> MCP.verify()
    assert {:error, _} = MCP.verify("forged")
  end
end
