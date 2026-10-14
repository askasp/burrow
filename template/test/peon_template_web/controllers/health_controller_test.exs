defmodule PeonTemplateWeb.HealthControllerTest do
  use PeonTemplateWeb.ConnCase, async: true

  test "GET /health", %{conn: conn} do
    assert conn |> get(~p"/health") |> text_response(200) == "ok"
  end
end
