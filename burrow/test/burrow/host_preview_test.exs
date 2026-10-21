defmodule Burrow.GitRepo.HostPreviewTest do
  use ExUnit.Case, async: true

  alias Burrow.GitRepo.HostPreview

  @moduletag :tmp_dir

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  test "runs the pack's start command on the host until it is stopped", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "index.html"), "hello")
    port = free_port()
    env = %{"PORT" => to_string(port)}

    preview =
      HostPreview.start(dir, "exec python3 -m http.server $PORT --bind 127.0.0.1", env)

    assert eventually(fn -> HostPreview.up?(port, "/") end)

    HostPreview.stop(dir, preview, "echo stopped $PORT", env)
    assert_receive {^preview, {:exit_status, _}}, 5_000
    refute HostPreview.up?(port, "/")
  end

  test "commands get the pack's env, not Burrow's own", %{tmp_dir: dir} do
    System.put_env("PEON_HOST_PREVIEW_TEST", "leaked")
    on_exit(fn -> System.delete_env("PEON_HOST_PREVIEW_TEST") end)

    preview =
      HostPreview.start(dir, "echo \"[$PEON_HOST_PREVIEW_TEST][$NAME]\"", %{"NAME" => "app"})

    assert_receive {^preview, {:data, "[][app]\n"}}, 5_000
    assert_receive {^preview, {:exit_status, 0}}, 5_000

    assert HostPreview.stop(dir, nil, "echo \"$NAME down\"", %{"NAME" => "app"}) ==
             "app down\n"
  end
end
