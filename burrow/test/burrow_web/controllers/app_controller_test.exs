defmodule BurrowWeb.AppControllerTest do
  use BurrowWeb.ConnCase, async: true

  import Burrow.AccountsFixtures
  import Burrow.ProjectFixtures

  alias Burrow.Projects

  setup do
    owner = user_fixture()
    %{owner: owner, project: project_fixture(%{auth: "burrow", user_id: owner.id})}
  end

  test "whoever sees an internal app goes on to it, logged in as themselves", %{
    conn: conn,
    owner: owner,
    project: project
  } do
    conn = conn |> log_in_user(owner) |> get(~p"/projects/#{project}/app?#{[to: "/x?y=1"]}")

    app = Burrow.Ports.url(21049)
    assert ^app <> "/burrow/login?" <> query = redirected_to(conn)
    assert %{"token" => token, "return_to" => "/x?y=1"} = URI.decode_query(query)
    key = Projects.secret(project, "app login")
    email = owner.email

    assert {:ok, %{"email" => ^email, "admin" => true}} =
             Plug.Crypto.verify(key, "burrow login", token, max_age: 60)
  end

  test "it starts on the app's first page, and only goes to its own pages", %{
    conn: conn,
    owner: owner,
    project: project
  } do
    conn = log_in_user(conn, owner)

    assert conn |> get(~p"/projects/#{project}/app") |> redirected_to() =~ "return_to=%2F"

    for to <- ["//evil.example", "https://evil.example/", "/\\evil.example"],
        do: assert(conn |> get(~p"/projects/#{project}/app?#{[to: to]}") |> response(400))
  end

  test "nobody else, and no app that isn't internal", %{conn: conn, project: project} do
    assert_error_sent 404, fn ->
      conn |> log_in_user(user_fixture()) |> get(~p"/projects/#{project}/app")
    end

    owner = user_fixture()
    shop = project_fixture(%{user_id: owner.id})
    assert conn |> log_in_user(owner) |> get(~p"/projects/#{shop}/app") |> response(404)

    assert conn |> get(~p"/projects/#{project}/app") |> redirected_to() == ~p"/users/log-in"
  end
end
