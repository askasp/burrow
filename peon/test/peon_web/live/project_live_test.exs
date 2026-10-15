defmodule PeonWeb.ProjectLiveTest do
  use PeonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Peon.{Chats, Code, Store, Verifier}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do end")
    {:ok, base} = Store.import_dir(dir, "app", "App", %{kind: :human, id: "aksel"})
    %{base: base}
  end

  test "the ship bar shows main and the incidents toggle opens the panel", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "main"
    refute has_element?(view, "#ship-panel")

    view |> element("[data-kb-action=ship]") |> render_click()
    assert has_element?(view, "#ship-panel")
  end

  test "auto-promote is a human switch, recorded with who turned it on", %{conn: conn} do
    Application.put_env(:peon, :env_ports, %{"staging" => 1, "prod" => 2})
    on_exit(fn -> Application.delete_env(:peon, :env_ports) end)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("[data-kb-action=ship]") |> render_click()
    view |> element("#auto-promote") |> render_click()

    assert Peon.Project.settings() |> Map.take(["auto_promote", "auto_promote_by"]) ==
             %{"auto_promote" => true, "auto_promote_by" => "dev"}

    assert render(view) =~ "Prod follows every healthy staging deploy"
  end

  test "a held changeset can be landed from its chat", %{conn: conn, base: base} do
    chat = Chats.create("Bump deps", "aksel")
    cs = passed(base.id, "mix.exs", "defmodule App.MixProject do @x 1 end", chat.id)

    {:ok, view, _html} = live(conn, ~p"/c/#{chat.id}")
    assert render(view) =~ "Needs your review: it changes mix.exs"

    view |> element("[data-kb-action=land]") |> render_click()
    assert Code.ref("main").changeset_id == cs.id
    assert render(view) =~ "on main"
  end

  test "main broken by a changeset offers a revert", %{conn: conn, base: base} do
    cs = passed(base.id, "lib/app.ex", "defmodule App do def x, do: 1 end", nil)
    {:ok, landed} = Store.land(cs.id, "peon")

    {:ok, _} =
      Store.set_verify(landed.id, %{"status" => "failed", "steps" => [], "blamed" => true})

    assert Verifier.culprit().id == landed.id

    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ "broken by ##{landed.id}"

    view |> element("button", "revert") |> render_click()
    assert render(view) =~ "Revert submitted"

    # Info flashes clear themselves.
    send(view.pid, :clear_info)
    refute render(view) =~ "Revert submitted"
  end

  defp passed(parent, path, content, chat_id) do
    {:ok, cs} =
      Store.submit(%{
        parent: parent,
        intent: "change #{path}",
        files: [%{"path" => path, "content" => content}],
        author: %{kind: :ai, id: "agent"},
        conversation_id: chat_id
      })

    {:ok, cs} = Store.set_status(cs.id, "passed", %{"steps" => []})
    cs
  end
end
