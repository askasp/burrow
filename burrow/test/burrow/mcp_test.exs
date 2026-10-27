defmodule Burrow.Agent.MCPTest do
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.Agent.MCP

  defp rpc(method, caller, params \\ %{}),
    do:
      MCP.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}, caller)

  test "initialize, tools/list and errors follow JSON-RPC; a repo project gets fewer tools" do
    app = {project_fixture(), "chat"}
    repo = {project_fixture(%{repo_url: "https://github.com/acme/shop.git"}), "chat"}

    assert %{result: %{serverInfo: %{name: "peon"}, protocolVersion: "2025-06-18"}} =
             rpc("initialize", app, %{"protocolVersion" => "2025-06-18"})

    assert MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, app) == nil

    names = fn caller -> for t <- rpc("tools/list", caller).result.tools, do: t.name end

    assert names.(app) ==
             ~w(submit_changeset restart_preview restore runtime secrets request_secret)

    assert names.(repo) ==
             ~w(submit_changeset restart_preview secrets pull_request comment_on_pull_request
                request_secret)

    assert %{error: %{code: -32601}} = rpc("nope", app)
  end

  test "tools/call runs a tool for the chat's project" do
    {project, _} = app = {project_fixture(), "chat"}
    :ok = Burrow.Secrets.put(project.id, "SLACK_TOKEN", "xoxb-1", "ada")

    assert %{result: %{content: [%{text: "- SLACK_TOKEN: set"}], isError: false}} =
             rpc("tools/call", app, %{"name" => "secrets"})

    assert %{result: %{isError: true}} = rpc("tools/call", app, %{"name" => "nope"})
  end

  test "the agent never sees Burrow's own GITHUB_TOKEN as one of its secrets" do
    {project, _} =
      repo = {project_fixture(%{repo_url: "https://github.com/acme/shop.git"}), "chat"}

    :ok = Burrow.Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")

    assert %{result: %{content: [%{text: "No secrets yet." <> _}]}} =
             rpc("tools/call", repo, %{"name" => "secrets"})

    args = %{"name" => "GITHUB_TOKEN", "why" => "to read a PR"}

    assert %{result: %{content: [%{text: text}], isError: true}} =
             rpc("tools/call", repo, %{"name" => "request_secret", "arguments" => args})

    assert text =~ "peon_pull_request"
  end

  test "tokens name one chat of one project" do
    assert {:ok, {7, "abc"}} = 7 |> MCP.token("abc") |> MCP.verify()
    assert {:error, _} = MCP.verify("forged")
  end
end
