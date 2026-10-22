defmodule BurrowWeb.DesignControllerTest do
  use BurrowWeb.ConnCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.Chats
  alias BurrowWeb.DesignController

  setup do
    project = project_fixture()

    history!(project, %{"design/a.html" => "<!DOCTYPE html>\n<title>a</title>", "lib/x.ex" => "x"})

    {:ok, chat} = Chats.create_empty(project.id, "ada")
    %{base: DesignController.path(project.id, chat.id)}
  end

  test "serves a board sandboxed, reporting its script errors, without a session", %{
    conn: conn,
    base: base
  } do
    conn = get(conn, base <> "/a.html")

    assert response(conn, 200) =~
             ~r{\A<!DOCTYPE html><script>.*postMessage.*</script>\n<title>a</title>\z}

    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox allow-scripts"
  end

  test "nothing outside design/, and nothing without a good token", %{conn: conn, base: base} do
    assert conn |> get(base <> "/../lib/x.ex") |> response(404)
    assert conn |> get(base <> "/nope.html") |> response(404)
    assert conn |> get("/design/forged/a.html") |> response(404)
  end
end
