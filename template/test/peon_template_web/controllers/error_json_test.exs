defmodule PeonTemplateWeb.ErrorJSONTest do
  use PeonTemplateWeb.ConnCase, async: true

  test "renders 404" do
    assert PeonTemplateWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert PeonTemplateWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
