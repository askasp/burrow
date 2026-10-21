defmodule Peon.PreviewPackTest do
  use ExUnit.Case, async: true

  alias Peon.PreviewPack

  @moduletag :tmp_dir

  defp write(dir, pack) do
    File.mkdir_p!(Path.join(dir, ".peon"))
    File.write!(Path.join(dir, ".peon/preview.json"), Jason.encode!(pack))
  end

  test "a repo without a pack has no preview", %{tmp_dir: dir} do
    assert PreviewPack.load(dir) == :none
  end

  test "a pack fills in its env from the claimed ports and their URLs", %{tmp_dir: dir} do
    write(dir, %{
      "ports" => ["app", "api"],
      "local_ports" => ["db"],
      "env" => %{
        "COMPOSE_PROJECT_NAME" => "{name}",
        "API_URL" => "{url.api}",
        "DB" => "postgres://localhost:{port.db}/dev"
      },
      "start" => "docker compose up -d",
      "stop" => "docker compose down"
    })

    assert {:ok, pack} = PreviewPack.load(dir)
    assert pack.frame == "app"
    assert pack.ready == "/"
    assert PreviewPack.port_count(pack) == 2

    env =
      PreviewPack.env(
        pack,
        %{"app" => 5011, "api" => 5012, "db" => 40_001},
        &"https://p-#{&1}.example.com",
        "peon-preview-amino-ab12"
      )

    assert env["COMPOSE_PROJECT_NAME"] == "peon-preview-amino-ab12"
    assert env["API_URL"] == "https://p-5012.example.com"
    assert env["DB"] == "postgres://localhost:40001/dev"
    assert env["PORT"] == "5011"
    assert env["PEON_PREVIEW_URL"] == "https://p-5011.example.com"
    assert env["PEON_PORT_DB"] == "40001"
    refute Map.has_key?(env, "PEON_URL_DB")
  end

  test "mistakes come back as messages the agent can act on", %{tmp_dir: dir} do
    bad = fn pack ->
      write(dir, pack)
      assert {:error, message} = PreviewPack.load(dir)
      message
    end

    ok = %{"ports" => ["app"], "start" => "npm run dev"}

    assert bad.(Map.delete(ok, "start")) =~ "start"
    assert bad.(Map.put(ok, "ports", [])) =~ "ports"
    assert bad.(Map.put(ok, "ports", ["App"])) =~ "names"
    assert bad.(Map.put(ok, "local_ports", ["app"])) =~ "named twice"
    assert bad.(Map.put(ok, "frame", "api")) =~ "frame"
    assert bad.(Map.put(ok, "ready", "health")) =~ "ready"
    assert bad.(Map.put(ok, "env", %{"X" => "{url.db}"})) =~ "{url.db}"
    assert bad.(Map.put(ok, "env", %{"X" => 1})) =~ "string"

    File.write!(Path.join(dir, ".peon/preview.json"), "{nope")
    assert {:error, message} = PreviewPack.load(dir)
    assert message =~ "not valid JSON"
  end
end
