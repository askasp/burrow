defmodule Peon.Env.ProbeTest do
  # The probe (totem/priv/probe.exs) in a node of its own, as it runs in an
  # environment's container: this test plays Peon's side of the socket.
  use ExUnit.Case, async: true

  @moduletag timeout: 60_000

  setup do
    # A socket's path has at most 107 bytes; the test's tmp_dir is longer.
    path = Path.join(System.tmp_dir!(), "peon-probe-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: 4, active: false])

    telemetry = Path.join(Mix.Project.build_path(), "lib/telemetry/ebin")

    # The "app": its endpoint is a registered process, up a moment after the
    # probe was loaded, and it logs an error once asked.
    app = """
    Application.ensure_all_started(:telemetry)
    Process.sleep(300)
    Process.register(spawn(fn -> Process.sleep(:infinity) end), Probe.Test.Endpoint)
    Process.sleep(1_500)
    :logger.error("probe test boom")
    Process.sleep(:infinity)
    """

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-pa", telemetry, "-r", Peon.Env.probe_file(), "-e", app],
        env: [
          {~c"PEON_PROBE_SOCKET", to_charlist(path)},
          {~c"PEON_OTP_APP", ~c"probe_test"},
          {~c"PEON_ENDPOINT", ~c"Probe.Test.Endpoint"}
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)]) end)
    %{listener: listener}
  end

  test "the probe dials in once the app is up, answers, and takes an upgrade", %{
    listener: listener
  } do
    {:ok, conn} = :gen_tcp.accept(listener, 30_000)
    assert %{"event" => "connected", "version" => version} = receive_json(conn)
    assert version == Peon.Env.probe_version()

    # What the app logs as an error reaches Peon.
    assert %{"message" => "probe test boom"} = receive_until(conn, &(&1["event"] == "error"))

    send_json(conn, %{"id" => 1, "cmd" => "processes", "limit" => 3})
    assert %{"reply" => 1, "ok" => true, "result" => processes} = receive_reply(conn, 1)
    assert length(processes) == 3

    # A newer probe replaces it over the socket; it dials again with that one.
    source =
      Peon.Env.probe_file()
      |> File.read!()
      |> String.replace("@version #{version}", "@version #{version + 1}")

    send_json(conn, %{"id" => 2, "cmd" => "upgrade", "source" => source})
    assert %{"reply" => 2, "ok" => true} = receive_reply(conn, 2)

    {:ok, conn} = :gen_tcp.accept(listener, 10_000)
    assert %{"event" => "connected", "version" => new} = receive_json(conn)
    assert new == version + 1
  end

  defp send_json(conn, map), do: :ok = :gen_tcp.send(conn, Jason.encode!(map))

  defp receive_json(conn) do
    {:ok, data} = :gen_tcp.recv(conn, 0, 10_000)
    Jason.decode!(data)
  end

  # Stats arrive in between.
  defp receive_reply(conn, id), do: receive_until(conn, &(&1["reply"] == id))

  defp receive_until(conn, fun) do
    message = receive_json(conn)
    if fun.(message), do: message, else: receive_until(conn, fun)
  end
end
