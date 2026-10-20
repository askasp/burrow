defmodule BurrowWeb.PeonProxyTest do
  use Burrow.DataCase, async: false

  import Burrow.AccountsFixtures

  alias Burrow.Accounts.Scope
  alias Burrow.{Projects, Repo}

  # Stands in for a Peon: says what it got, sets two cookies, echoes a socket.
  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      if get_req_header(conn, "upgrade") != [] do
        conn |> WebSockAdapter.upgrade(BurrowWeb.PeonProxyTest.Echo, nil, []) |> halt()
      else
        {:ok, body, conn} = read_body(conn)

        conn
        |> prepend_resp_headers([{"set-cookie", "a=1"}, {"set-cookie", "b=2"}])
        |> send_resp(200, "#{conn.method} #{conn.request_path}?#{conn.query_string} #{body}")
      end
    end
  end

  defmodule Echo do
    @behaviour WebSock
    def init(state), do: {:ok, state}
    def handle_in({text, opcode: :text}, state), do: {:push, {:text, "echo " <> text}, state}
    def handle_info(_message, state), do: {:ok, state}
  end

  setup do
    upstream = start_supervised!({Bandit, plug: Upstream, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, up_port}} = ThousandIsland.listener_info(upstream)

    burrow =
      start_supervised!(
        {Bandit, plug: BurrowWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}},
        id: :burrow
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(burrow)

    {:ok, project} = Projects.create(Scope.for_user(user_fixture()), %{"name" => "Proxied"})

    Repo.update_all(Ecto.Query.from(p in Projects.Project, where: p.id == ^project.id),
      set: [port: up_port]
    )

    %{base: "http://127.0.0.1:#{port}", port: port, up: up_port}
  end

  test "a workspace's requests go to its Peon without the /w/<port>", %{base: base, up: up} do
    resp = Req.post!("#{base}/w/#{up}/c/abc?x=1", body: "hi", redirect: false, retry: false)
    assert resp.body == "POST /c/abc?x=1 hi"
    assert resp.headers["set-cookie"] == ["a=1", "b=2"]

    assert %{status: 308, headers: %{"location" => [location]}} =
             Req.get!("#{base}/w/#{up}", redirect: false, retry: false)

    assert location == "/w/#{up}/"
  end

  test "only ports of projects are passed on", %{base: base} do
    assert Req.get!("#{base}/w/22/", redirect: false, retry: false).status == 404
  end

  test "its socket goes through too", %{port: port, up: up} do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/w/#{up}/live/websocket?vsn=2", [])

    {conn, ws} = await_upgrade(conn, ref)
    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, "zug"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    assert receive_text(conn, ref, ws) == "echo zug"
  end

  defp await_upgrade(conn, ref, acc \\ []) do
    receive do
      message ->
        {:ok, conn, responses} =
          with :unknown <- Mint.WebSocket.stream(conn, message), do: {:ok, conn, []}

        acc = acc ++ responses

        if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
          {:status, _, status} = List.keyfind(acc, :status, 0)
          {:headers, _, headers} = List.keyfind(acc, :headers, 0)
          {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers)
          {conn, ws}
        else
          await_upgrade(conn, ref, acc)
        end
    after
      2_000 -> flunk("no upgrade")
    end
  end

  defp receive_text(conn, ref, ws) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, _conn, [{:data, ^ref, data}]} ->
            {:ok, _ws, [{:text, text}]} = Mint.WebSocket.decode(ws, data)
            text

          :unknown ->
            receive_text(conn, ref, ws)
        end
    after
      2_000 -> flunk("no echo")
    end
  end
end
