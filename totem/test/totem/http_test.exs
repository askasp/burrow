defmodule Totem.HttpTest do
  # Two real apps served by Bandit with Totem.Plug: a dev app that is its own
  # origin, and a prod app that only runs. Over HTTP: check the dev app out,
  # push a change (checked in a scratch build, landed, loaded hot), see a
  # broken draft fail its check over MCP, then promote dev's main to prod.
  use ExUnit.Case, async: true

  import Totem.Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  test "clone and push and check over MCP and promote dev to prod", %{tmp_dir: tmp_dir} do
    [dev_port, prod_port] = for _ <- 1..2, do: free_port()
    dev = app!(Path.join(tmp_dir, "dev"), web())
    prod = app!(Path.join(tmp_dir, "prod"), web())

    # Prod runs on its own, a plain runtime.
    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", "--no-halt"],
        cd: prod,
        env: [
          {~c"MIX_ENV", ~c"dev"},
          {~c"TOTEM_TOKEN", ~c"prod-secret"},
          {~c"WEB_PORT", to_charlist(prod_port)}
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("pkill", ["-9", "-P", to_string(os_pid)]) end)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)]) end)

    clone = Path.join(tmp_dir, "clone")

    result =
      run!(
        dev,
        """
        url = "http://127.0.0.1:#{dev_port}/_totem"
        prod = "http://127.0.0.1:#{prod_port}/_totem"
        clone = #{inspect(clone)}
        Mix.Tasks.Totem.Clone.run([url, clone])

        File.cd!(clone, fn ->
          path = "lib/demo/counter.ex"
          File.write!(path, String.replace(File.read!(path), ~s("v1"), ~s("v2")))
          Mix.Tasks.Totem.Push.run(["--intent", "v2"])
        end)

        landed = [Demo.Counter.label(), Totem.current().label]

        mcp = fn body ->
          request = {~c"\#{url}/mcp", [{~c"authorization", ~c"Bearer dev-secret"}], ~c"application/json", JSON.encode!(body)}
          {:ok, {{_, 200, _}, _, data}} = :httpc.request(:post, request, [], body_format: :binary)
          JSON.decode!(data)["result"]
        end

        tools = for t <- mcp.(%{jsonrpc: "2.0", id: 1, method: "tools/list"})["tools"], do: t["name"]
        call = fn name, args -> mcp.(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: name, arguments: args}}) end
        broken = %{path: "lib/demo/counter.ex", content: "defmodule Demo.Counter do\\n  def label, do:\\nend\\n"}
        written = call.("write_draft", %{id: "broken", intent: "breaks it", files: [broken]})
        checked = call.("check_draft", %{id: "broken"})

        # Prod is up once its Totem answers.
        up = fn up, n ->
          case :httpc.request(:get, {~c"\#{prod}/current", [{~c"authorization", ~c"Bearer prod-secret"}]}, [], []) do
            {:ok, {{_, 200, _}, _, _}} -> :ok
            _ when n > 0 -> Process.sleep(1_000); up.(up, n - 1)
          end
        end

        up.(up, 180)
        System.put_env("SRC_TOKEN", "dev-secret")
        System.put_env("DST_TOKEN", "prod-secret")
        Mix.Tasks.Totem.Promote.run([url, prod, "--watch", "1"])

        {200, prod_now} = Totem.Remote.get!(prod, "/current", "prod-secret")
        {200, prod_file} = Totem.Remote.get!(prod, "/files/lib/demo/counter.ex", "prod-secret")
        {:ok, {{_, unauthorized, _}, _, _}} = :httpc.request(:get, {~c"\#{url}/current", []}, [], [])

        %{
          landed: landed,
          clone: File.exists?(Path.join(clone, "mix.exs")),
          tools: tools,
          written: written["isError"],
          checked: [checked["isError"], hd(checked["content"])["text"] =~ "error"],
          prod: [prod_now["label"], prod_file =~ ~s("v2")],
          unauthorized: unauthorized
        }
        """,
        [{"TOTEM_TOKEN", "dev-secret"}, {"TOTEM_ORIGIN", "1"}, {"WEB_PORT", "#{dev_port}"}]
      )

    assert result["landed"] == ["v2", "main #2"]
    assert result["clone"]

    assert Enum.all?(
             ~w(read_file write_draft check_draft land_draft log),
             &(&1 in result["tools"])
           )

    assert result["written"] == false
    assert result["checked"] == [true, true]
    assert [label, true] = result["prod"]
    assert label =~ "#2"
    assert result["unauthorized"] == 401
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # The app with Totem.Plug on WEB_PORT, except under `mix test` (a check's scratch build).
  defp web do
    [
      deps: [~s({:plug, "~> 1.14"}), ~s({:bandit, "~> 1.5"})],
      files: [
        {"lib/demo/application.ex",
         """
         defmodule Demo.Application do
           use Application

           def start(_, _) do
             port = String.to_integer(System.get_env("WEB_PORT", "4000"))
             web = if Mix.env() == :test, do: [], else: [{Bandit, plug: Demo.Web, port: port, startup_log: false}]
             Supervisor.start_link([Demo.Counter | web], strategy: :one_for_one)
           end
         end
         """},
        {"lib/demo/web.ex",
         """
         defmodule Demo.Web do
           use Plug.Builder
           plug Totem.Plug
           plug :hello
           def hello(conn, _), do: send_resp(conn, 200, "hello")
         end
         """},
        {"test/test_helper.exs", "ExUnit.start()\n"},
        {"test/demo_test.exs",
         """
         defmodule DemoTest do
           use ExUnit.Case
           test "it has a label", do: assert(is_binary(Demo.Counter.label()))
         end
         """}
      ]
    ]
  end
end
