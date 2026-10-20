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
    # Where closing a chat removes its files
    Application.put_env(:peon, :data_dir, dir)
    on_exit(fn -> Application.delete_env(:peon, :data_dir) end)
    %{base: base}
  end

  test "the workspace opens on a new empty chat, with nothing built yet", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    assert has_element?(view, ".ctab[aria-selected=true] .cdot.new")
    assert has_element?(view, ".ctab", "What should App do?")
    assert has_element?(view, ".ws-hello", "What should App do?")
    assert has_element?(view, ".pbar-meta", "app · nothing built yet")
    assert has_element?(view, ".ws-prev-empty", "Nothing here yet")
    # Its agent starts with the first message, not before.
    assert [%{started_at: nil}] = Chats.list()
  end

  test "up to four chats; closing an empty one deletes it", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    for _ <- 1..3, do: view |> element("#new-chat") |> render_click()
    assert length(Chats.list()) == 4
    assert has_element?(view, "#new-chat[disabled]")
    assert has_element?(view, "span[title='Up to 4 chats. Merge or close one first.']")

    [first | _] = Chats.list()
    view |> element("#tab-#{first.id} .cx") |> render_click()
    assert_eventually(fn -> length(Chats.list()) == 3 end)
    refute has_element?(view, "#new-chat[disabled]")
  end

  test "deploys and usage replace the preview; auto-promote is a human switch", %{conn: conn} do
    Application.put_env(:peon, :env_ports, %{"staging" => 1, "prod" => 2})
    on_exit(fn -> Application.delete_env(:peon, :env_ports) end)

    {:ok, view, _html} = open(conn)
    refute has_element?(view, "#overview")
    view |> element("#overview-btn") |> render_click()
    assert has_element?(view, "#overview-btn[aria-pressed=true]")
    assert has_element?(view, "#overview .env .eyebrow", "staging")
    refute has_element?(view, ".vbar")

    view |> element("#auto-promote") |> render_click()

    assert Peon.Project.settings() |> Map.take(["auto_promote", "auto_promote_by"]) ==
             %{"auto_promote" => true, "auto_promote_by" => "dev"}

    assert render(view) =~ "Prod follows every healthy staging deploy"

    view |> element("#overview button", "Back to preview") |> render_click()
    assert has_element?(view, ".vbar .seg button", "staging")
  end

  test "a live-only project calls prod live and offers staging and prod", %{conn: conn} do
    Application.put_env(:peon, :env_ports, %{"staging" => 1, "prod" => 2})
    on_exit(fn -> Application.delete_env(:peon, :env_ports) end)
    Peon.Project.put_settings(%{"envs" => "live"})

    {:ok, view, _html} = open(conn)
    assert has_element?(view, ".vbar .seg button", "live")
    refute has_element?(view, ".vbar .seg button", "staging")
    assert has_element?(view, "#more-menu button", "Add staging and prod")

    view |> element("#more-menu button", "Add staging and prod") |> render_click()
    assert_eventually(fn -> Peon.Project.settings()["envs"] == "pipeline" end)
  end

  test "secrets are added in their dialog; values never show", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    view |> element("#more-menu [data-kb-key=k]") |> render_click()
    assert has_element?(view, "#secrets-panel")

    view
    |> form("#secrets-panel form[id^=secret-new]", %{"name" => "slack_token", "value" => "xoxb-1"})
    |> render_submit()

    assert Peon.Secrets.env() == %{"SLACK_TOKEN" => "xoxb-1"}
    html = render(view)
    assert html =~ "SLACK_TOKEN"
    refute html =~ "xoxb-1"

    view |> element("button[phx-value-name=SLACK_TOKEN]") |> render_click()
    assert Peon.Secrets.env() == %{}

    view |> element("#secrets-panel button", "Close") |> render_click()
    refute has_element?(view, "#secrets-panel")
  end

  test "a secret the agent asked for gets a box in its chat", %{conn: conn} do
    chat = Chats.create("Digest", "aksel")
    {:ok, :requested} = Peon.Secrets.request("SLACK_TOKEN", "Posts to #ops", chat.id)

    {:ok, view, _html} = live(conn, ~p"/c/#{chat.id}")
    assert render(view) =~ "Peon needs a key"
    assert render(view) =~ "Posts to #ops"

    view |> form("form[id^=connect-SLACK_TOKEN]", %{"value" => "xoxb-1"}) |> render_submit()
    assert Peon.Secrets.env() == %{"SLACK_TOKEN" => "xoxb-1"}
    refute render(view) =~ "Peon needs a key"
  end

  test "a held changeset is merged from its chat, which then closes for changes", %{
    conn: conn,
    base: base
  } do
    chat = Chats.create("Bump deps", "aksel")
    cs = passed(base.id, "mix.exs", "defmodule App.MixProject do @x 1 end", chat.id)

    {:ok, view, _html} = live(conn, ~p"/c/#{chat.id}")
    assert render(view) =~ "Needs your review: it changes mix.exs"
    assert has_element?(view, "#tab-#{chat.id} .cdot.waiting")
    assert has_element?(view, "#tab-#{chat.id} .n", "##{cs.id}")

    view |> element("[data-kb-key=a]") |> render_click()
    assert Code.ref("main").changeset_id == cs.id
    assert has_element?(view, "#tab-#{chat.id} .cdot.working")
    assert has_element?(view, "#chat-input[disabled]")

    assert has_element?(
             view,
             "#chat-input[placeholder='Merged. Start a new chat for the next change.']"
           )
  end

  test "main broken by a changeset offers a revert", %{conn: conn, base: base} do
    cs = passed(base.id, "lib/app.ex", "defmodule App do def x, do: 1 end", nil)
    {:ok, landed} = Store.land(cs.id, "peon")

    {:ok, _} =
      Store.set_verify(landed.id, %{"status" => "failed", "steps" => [], "blamed" => true})

    assert Verifier.culprit().id == landed.id

    {:ok, view, _html} = open(conn)
    assert render(view) =~ "tests fail since ##{landed.id}"

    view |> element("button", "revert") |> render_click()
    assert render(view) =~ "Revert submitted"

    # Info flashes clear themselves.
    send(view.pid, :clear_info)
    refute render(view) =~ "Revert submitted"
  end

  # "/" opens the first chat (a new empty one when there is none).
  defp open(conn) do
    {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/")
    live(conn, to)
  end

  defp assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(20) && assert_eventually(fun, tries - 1)
    end
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
