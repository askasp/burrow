defmodule PeonWeb.ManifestControllerTest do
  use PeonWeb.ConnCase, async: true

  test "the manifest is public and named after the project", %{conn: conn} do
    manifest = conn |> get(~p"/manifest.webmanifest") |> response(200) |> Jason.decode!()
    assert manifest["display"] == "standalone"
    assert manifest["name"] =~ "Peon"
  end
end
