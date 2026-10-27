defmodule Burrow.BridgeTest do
  # The real Burrow Bridge, built from bridge/ for this computer, against
  # Burrow served on a port of its own.
  use Burrow.DataCase, async: false

  import Burrow.AccountsFixtures

  alias Burrow.{Bridge, Computers}

  @moduletag :tmp_dir

  setup do
    if System.find_executable("go") == nil, do: raise("Go is needed to build Burrow Bridge")

    {:ok, server} =
      Bandit.start_link(plug: BurrowWeb.Endpoint, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {out, 0} = System.cmd("go", ["env", "GOOS", "GOARCH"])
    [goos, goarch] = String.split(out)
    {:ok, bin} = Bridge.binary("#{goos}-#{goarch}")
    %{url: "http://127.0.0.1:#{port}", bin: bin}
  end

  test "Peon's calls run on the computer, inside its folders only, until it's removed",
       %{url: url, bin: bin, tmp_dir: tmp} do
    user = user_fixture()
    shared = Path.join(tmp, "shared")
    File.mkdir_p!(shared)
    File.write!(Path.join(tmp, "secret.txt"), "no")

    {:ok, pairing} =
      Computers.start_pairing(%{"name" => "laptop", "os" => "linux", "arch" => "amd64"})

    {:ok, _} = Computers.approve(user, pairing.user_code)
    {:ok, token, computer} = Computers.claim_token(pairing.device_code)

    config = Path.join(tmp, "config.json")

    File.write!(
      config,
      Jason.encode!(%{
        server: url,
        token: token,
        computer: computer.id,
        name: "laptop",
        folders: [%{path: shared, write: true}]
      })
    )

    Computers.subscribe(user.id)

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run"],
        env: [{~c"BURROW_BRIDGE_CONFIG", String.to_charlist(config)}]
      ])

    assert_receive {:computer, _}, 10_000
    assert Computers.online?(computer.id)
    assert [%{folders: [%{"path" => ^shared, "write" => true}]}] = Computers.list(user.id)

    file = Path.join(shared, "notes/a.txt")

    assert {:ok, %{"created" => true}} =
             Computers.call(computer.id, "write", %{path: file, content: "hello"})

    assert {:ok, %{"content" => "hello"}} = Computers.call(computer.id, "read", %{path: file})

    assert {:ok, %{"replaced" => 1}} =
             Computers.call(computer.id, "edit", %{path: file, old: "hello", new: "hi"})

    assert File.read!(file) == "hi"

    assert {:error, refused} =
             Computers.call(computer.id, "read", %{path: Path.join(tmp, "secret.txt")})

    assert refused =~ "outside the folders"

    assert {:ok, %{"folders" => []}} = Computers.forget_folder(computer.id, shared)
    assert_receive {:computer, _}, 5_000
    assert [%{folders: []}] = Computers.list(user.id)
    assert {:error, _} = Computers.call(computer.id, "read", %{path: file})

    Computers.remove(computer)
    assert_receive {^port, {:exit_status, 1}}, 5_000
  end
end
