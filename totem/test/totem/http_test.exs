defmodule Totem.HttpTest do
  # Totem.Plug in a real app served by Bandit: checking the code out, pushing
  # a change (loaded hot), a stale push, pulling, and MCP, all over HTTP.
  use ExUnit.Case, async: true

  import Totem.Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  test "clone and push and pull and MCP against the running app", %{tmp_dir: tmp_dir} do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    dir =
      app!(tmp_dir,
        deps: [~s({:plug, "~> 1.14"}), ~s({:bandit, "~> 1.5"})],
        children: ["{Bandit, plug: Demo.Web, port: #{port}, startup_log: false}"],
        files: [
          {"lib/demo/web.ex",
           """
           defmodule Demo.Web do
             use Plug.Builder
             plug Totem.Plug
             plug :hello
             def hello(conn, _), do: send_resp(conn, 200, "hello")
           end
           """}
        ]
      )

    clone = Path.join(tmp_dir, "clone")

    result =
      run!(
        dir,
        """
        url = "http://127.0.0.1:#{port}/_totem"
        clone = #{inspect(clone)}
        Mix.Tasks.Totem.Clone.run([url, clone])

        File.cd!(clone, fn ->
          path = "lib/demo/counter.ex"
          File.write!(path, String.replace(File.read!(path), ~s("v1"), ~s("v2")))
          Mix.Tasks.Totem.Push.run(["--source", "test push"])
        end)

        label = Demo.Counter.label()
        source = hd(Totem.versions()).source

        extra = "defmodule Demo.Extra do\\n  def hi, do: :hi\\nend\\n"
        {:ok, _} = Totem.apply(%{base: Totem.current().version, files: [{"lib/demo/extra.ex", extra}]})

        stale =
          try do
            File.cd!(clone, fn ->
              File.write!("NOTES.md", "hi")
              Mix.Tasks.Totem.Push.run([])
            end)
            "pushed"
          rescue
            e in Mix.Error -> e.message
          end

        File.cd!(clone, fn ->
          Mix.Tasks.Totem.Pull.run([])
          Mix.Tasks.Totem.Push.run([])
        end)

        mcp = fn body ->
          request = {~c"\#{url}/mcp", [{~c"authorization", ~c"Bearer secret"}], ~c"application/json", JSON.encode!(body)}
          {:ok, {{_, 200, _}, _, data}} = :httpc.request(:post, request, [], body_format: :binary)
          JSON.decode!(data)
        end

        tools = for t <- mcp.(%{jsonrpc: "2.0", id: 1, method: "tools/list"})["result"]["tools"], do: t["name"]
        call = %{name: "read_file", arguments: %{path: "lib/demo/counter.ex"}}
        read = mcp.(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: call})["result"]["content"]

        {:ok, {{_, unauthorized, _}, _, _}} = :httpc.request(:get, {~c"\#{url}/current", []}, [], [])
        {:ok, {{_, 200, _}, _, page}} = :httpc.request(~c"http://127.0.0.1:#{port}/")

        %{
          label: label,
          source: source,
          stale: stale,
          pulled: File.exists?(Path.join(clone, "lib/demo/extra.ex")),
          notes: Totem.read("NOTES.md") == {:ok, "hi"},
          tools: tools,
          read_v2: hd(read)["text"] =~ ~s("v2"),
          unauthorized: unauthorized,
          page: to_string(page)
        }
        """,
        [{"TOTEM_TOKEN", "secret"}]
      )

    assert result["label"] == "v2"
    assert result["source"] == "test push"
    assert result["stale"] =~ "mix totem.pull"
    assert result["pulled"]
    assert result["notes"]
    assert "apply_changes" in result["tools"] and "read_file" in result["tools"]
    assert result["read_v2"]
    assert result["unauthorized"] == 401
    # Everything else goes on to the app.
    assert result["page"] == "hello"
  end
end
