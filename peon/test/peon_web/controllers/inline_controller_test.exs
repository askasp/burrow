defmodule PeonWeb.InlineControllerTest do
  use PeonWeb.ConnCase, async: false

  alias Peon.{Inline, Project, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    {:ok, _} = Store.import_dir(dir, "app", "App", %{kind: :human, id: "aksel"})
    Project.put_settings(%{"envs" => "live"})
    Application.put_env(:peon, :api_token, "secret-token")
    on_exit(fn -> Application.delete_env(:peon, :api_token) end)
    start_supervised!(Inline)
    :ok
  end

  test "Burrow reads the state with the shared token", %{conn: conn} do
    assert conn |> get(~p"/api/inline") |> json_response(401)
    assert build_conn() |> auth("wrong") |> get(~p"/api/inline") |> json_response(401)

    state = build_conn() |> auth("secret-token") |> get(~p"/api/inline") |> json_response(200)
    assert %{"mode" => "live", "chat" => nil, "live" => %{"tip" => nil}} = state
  end

  test "an empty message or nothing to merge is a conflict, with why", %{conn: conn} do
    conn = conn |> auth("secret-token") |> post(~p"/api/inline/send", %{text: " ", user: "a@b"})
    assert json_response(conn, 409) == %{"error" => "Write what Peon should do."}

    conn = build_conn() |> auth("secret-token") |> post(~p"/api/inline/merge", %{user: "a@b"})
    assert json_response(conn, 409) == %{"error" => "There is no passed changeset to merge."}
  end

  test "signing in from Burrow can open a chat, and only a chat", %{conn: _conn} do
    Application.put_env(:peon, :sso_secret, "sso-secret-at-least-twenty-bytes-long-0123456789")
    on_exit(fn -> Application.delete_env(:peon, :sso_secret) end)

    token =
      Phoenix.Token.sign("sso-secret-at-least-twenty-bytes-long-0123456789", "peon sso", "a@b")

    assert build_conn() |> get(~p"/sso?#{[token: token, to: "/c/abc12"]}") |> redirected_to() ==
             "/c/abc12"

    assert build_conn()
           |> get(~p"/sso?#{[token: token, to: "//evil.example"]}")
           |> redirected_to() ==
             "/"
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
