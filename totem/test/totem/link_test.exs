defmodule Totem.LinkTest do
  # The app dials the test, which plays the server's side (Peon's) of the
  # socket: events come in, commands go out, a change loads hot.
  use ExUnit.Case, async: true

  import Totem.Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: tmp_dir} do
    dir = app!(tmp_dir)
    # A socket's path has at most 107 bytes; the test's tmp_dir is longer.
    path = Path.join(System.tmp_dir!(), "totem-link-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: 4, active: false])

    # The app logs an error a moment after it started.
    script =
      ~s|Process.sleep(1_500); require Logger; Logger.error("link test boom"); Process.sleep(:infinity)|

    port =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", "-e", script],
        cd: dir,
        env: [{~c"MIX_ENV", ~c"dev"}, {~c"TOTEM_LINK", to_charlist(path)}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("pkill", ["-9", "-P", to_string(os_pid)]) end)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)]) end)
    %{listener: listener, dir: dir}
  end

  test "the app dials in, reports, and loads a change sent over the link", %{
    listener: listener,
    dir: dir
  } do
    {:ok, conn} = :gen_tcp.accept(listener, 60_000)

    assert %{"event" => "connected", "protocol" => 2, "current" => current} =
             receive_json(conn)

    assert Map.has_key?(current["tree"], "lib/demo/counter.ex")

    unless current["ready"], do: receive_until(conn, &(&1["event"] == "ready"))

    assert %{"message" => "link test boom", "fingerprint" => _} =
             receive_until(conn, &(&1["event"] == "error"))

    # Only the contents the app doesn't have, then the change by hash.
    source = File.read!(Path.join(dir, "lib/demo/counter.ex"))
    v2 = String.replace(source, ~s("v1"), ~s("v2"))
    hash = Totem.Blob.hash(v2)

    send_json(conn, %{
      "id" => 1,
      "cmd" => "missing",
      "hashes" => [hash, current["tree"]["mix.exs"]]
    })

    assert %{"ok" => true, "result" => %{"missing" => [^hash]}} = receive_reply(conn, 1)

    send_json(conn, %{"id" => 2, "cmd" => "blobs", "contents" => [%{"content" => v2}]})
    assert %{"ok" => true, "result" => %{"hashes" => [^hash]}} = receive_reply(conn, 2)

    from = current["tree"]["lib/demo/counter.ex"]
    files = [%{"path" => "lib/demo/counter.ex", "from" => from, "blob" => hash}]
    send_json(conn, %{"id" => 3, "cmd" => "apply", "files" => files, "label" => "main #2"})

    assert %{"ok" => true, "result" => %{"mode" => "hot", "label" => "main #2"}} =
             receive_reply(conn, 3)

    # A stale `from` is refused, with the paths that moved.
    send_json(conn, %{"id" => 4, "cmd" => "apply", "files" => files})

    assert %{
             "ok" => false,
             "error" => %{"error" => "conflict", "paths" => ["lib/demo/counter.ex"]}
           } =
             receive_reply(conn, 4)

    send_json(conn, %{"id" => 5, "cmd" => "read", "path" => "lib/demo/counter.ex"})
    assert %{"ok" => true, "result" => %{"content" => ^v2}} = receive_reply(conn, 5)

    send_json(conn, %{"id" => 6, "cmd" => "processes", "limit" => 3})
    assert %{"ok" => true, "result" => processes} = receive_reply(conn, 6)
    assert length(processes) == 3

    assert %{"stats" => %{"process_count" => _, "usage" => _}} =
             receive_until(conn, &(&1["event"] == "stats"))
  end

  defp send_json(conn, map), do: :ok = :gen_tcp.send(conn, JSON.encode!(map))

  defp receive_json(conn) do
    {:ok, data} = :gen_tcp.recv(conn, 0, 30_000)
    JSON.decode!(data)
  end

  defp receive_until(conn, fun) do
    message = receive_json(conn)
    if fun.(message), do: message, else: receive_until(conn, fun)
  end

  defp receive_reply(conn, id), do: receive_until(conn, &(&1["reply"] == id))
end
