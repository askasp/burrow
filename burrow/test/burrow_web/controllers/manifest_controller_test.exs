defmodule BurrowWeb.ManifestControllerTest do
  use BurrowWeb.ConnCase, async: true

  test "phones get an installable manifest", %{conn: conn} do
    conn = get(conn, ~p"/manifest.webmanifest")
    assert response_content_type(conn, :json) =~ "application/manifest+json"
    manifest = Jason.decode!(response(conn, 200))
    assert %{"display" => "standalone", "start_url" => "/projects"} = manifest
    assert Enum.any?(manifest["icons"], &(&1["purpose"] == "maskable"))
  end
end
