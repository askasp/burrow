defmodule BurrowWeb.WorkspaceLiveTest do
  use BurrowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures
  import Burrow.ProjectHelpers

  alias Burrow.Accounts.Scope
  alias Burrow.{Accounts, Chats, Projects, Runs, Secrets, Teams}

  @moduletag :tmp_dir
  # The AI login check has no opencode to talk to in tests.
  @moduletag :capture_log

  setup :register_and_log_in_user

  setup %{user: user, tmp_dir: dir} do
    {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "App"})
    %{project: start_project!(project, dir)}
  end

  describe "the workspace" do
    test "opens on a new empty chat, with nothing built yet", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, ".ctab[aria-selected=true] .cdot.new")
      assert has_element?(view, ".ctab", "What should App do?")
      assert has_element?(view, ".ws-hello", "What should App do?")
      assert has_element?(view, ".pbar-meta", "app · nothing built yet")
      assert has_element?(view, ".ws-prev-empty", "Nothing here yet")
      # Its agent starts with the first message, not before.
      assert [%{started_at: nil}] = Chats.list(project.id)
    end

    test "is the project opened last, after the next login", %{conn: conn, project: project} do
      {:ok, _view, _html} = open(conn, project)
      assert redirected_to(get(conn, ~p"/")) == ~p"/projects/#{project.id}"
    end

    test "says it is starting until it is up", %{conn: conn, user: user} do
      {:ok, other} = Projects.create(Scope.for_user(user), %{"name" => "Later"})
      {:ok, view, html} = live(conn, ~p"/projects/#{other.id}")
      assert html =~ "Starting Later"

      Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, other.id, :running})
      assert_redirect(view, ~p"/projects/#{other.id}")
    end

    test "is only for those who can open the project", %{project: project} do
      stranger = user_fixture()
      conn = log_in_user(build_conn(), stranger)
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/projects/#{project.id}") end
    end
  end

  describe "chats" do
    test "up to four; closing an empty one deletes it", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)

      for _ <- 1..3, do: view |> element("#new-chat") |> render_click()
      assert length(Chats.list(project.id)) == 4
      assert has_element?(view, "#new-chat[disabled]")
      assert has_element?(view, "span[title='Up to 4 chats. Close one first.']")

      [first | _] = Chats.list(project.id)
      view |> element("#tab-#{first.id} .cx") |> render_click()
      assert_eventually(fn -> length(Chats.list(project.id)) == 3 end)
      refute has_element?(view, "#new-chat[disabled]")
    end

    test "a landed change ships from its card, and its chat closes for changes", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")
      run = Runs.start(project.id, "check", "main", change.id)
      Runs.finish(run, status: "passed")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert has_element?(view, "#tab-#{chat.id} .n", "##{change.id}")
      assert has_element?(view, ".ws-cs h2", "Change ##{change.id}")
      assert has_element?(view, "#chat-input[disabled]")

      view |> element(".ws-cs button", "Ship") |> render_click()
      assert Totem.Repo.ref(Projects.repo_dir(project), "prod") == change.id
      assert has_element?(view, "#tab-#{chat.id} .cdot.done")
    end

    test "main failing its check shows", %{conn: conn, project: project} do
      run = Runs.start(project.id, "check", "main", 1)
      Runs.finish(run, status: "failed", detail: "boot failed")

      {:ok, view, _html} = open(conn, project)
      assert render(view) =~ "Main #1 did not pass in prod mode"
    end
  end

  describe "secrets" do
    test "are added in their dialog; values never show", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)
      view |> element("#more-menu [data-kb-key=k]") |> render_click()
      assert has_element?(view, "#secrets-panel")

      view
      |> form("#secrets-panel form[id^=secret-new]", %{
        "name" => "slack_token",
        "value" => "xoxb-1"
      })
      |> render_submit()

      assert Secrets.env(project.id) == %{"SLACK_TOKEN" => "xoxb-1"}
      html = render(view)
      assert html =~ "SLACK_TOKEN"
      refute html =~ "xoxb-1"

      view |> element("button[phx-value-name=SLACK_TOKEN]") |> render_click()
      assert Secrets.env(project.id) == %{}

      view |> element("#secrets-panel button", "Close") |> render_click()
      refute has_element?(view, "#secrets-panel")
    end

    test "one the agent asked for gets a box in its chat", %{conn: conn, project: project} do
      chat = Chats.create(project.id, "Digest", "aksel")
      {:ok, :requested} = Secrets.request(project.id, "SLACK_TOKEN", "Posts to #ops", chat.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert render(view) =~ "Peon needs a key"
      assert render(view) =~ "Posts to #ops"

      view |> form("form[id^=connect-SLACK_TOKEN]", %{"value" => "xoxb-1"}) |> render_submit()
      assert Secrets.env(project.id) == %{"SLACK_TOKEN" => "xoxb-1"}
      refute render(view) =~ "Peon needs a key"
    end
  end

  describe "environments" do
    test "deploys and usage replace the preview; shipping by itself is a human switch", %{
      conn: conn,
      project: project,
      user: user
    } do
      Burrow.Repo.update_all(Projects.Project, set: [envs: "pipeline"])
      {:ok, view, _html} = open(conn, Projects.get(project.id))
      refute has_element?(view, "#overview")
      view |> element("#overview-btn") |> render_click()
      assert has_element?(view, "#overview-btn[aria-pressed=true]")
      assert has_element?(view, "#overview .env .eyebrow", "staging")
      refute has_element?(view, ".vbar")

      view |> element("#auto-ship") |> render_click()

      assert Projects.settings(project) |> Map.take(["auto_ship", "auto_ship_by"]) ==
               %{"auto_ship" => true, "auto_ship_by" => user.email}

      assert render(view) =~ "Every change that passes ships by itself"

      view |> element("#overview button", "Back to preview") |> render_click()
      assert has_element?(view, ".vbar .seg button", "staging")
    end

    test "a project without staging calls prod live, and staging can be added", %{
      conn: conn,
      project: project
    } do
      assert Projects.get(project.id).envs == "live"

      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, ".vbar .seg button", "live")
      refute has_element?(view, ".vbar .seg button", "staging")

      view |> element("#more-menu button", "Add staging") |> render_click()
      assert Projects.get(project.id).envs == "pipeline"
      assert render(view) =~ "Staging is set up"
    end
  end

  describe "the project rail" do
    test "shows the user's projects, and new ones as they come", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, other} = Projects.create(Scope.for_user(user), %{"name" => "Sauna Booking"})

      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, ".rail .ritem[aria-current=page]", "App")
      # Cells don't run in tests, so it shows as stopped.
      assert has_element?(view, ".rail a.ritem[href='/projects/#{other.id}'] .rhp.stopped")
      refute has_element?(view, ".rail.open")

      {:ok, third} = Projects.create(Scope.for_user(user), %{"name" => "Stash"})

      assert_eventually(fn ->
        has_element?(view, ".rail a.ritem[href='/projects/#{third.id}']")
      end)
    end

    test "opens, and the user's choice is kept", %{conn: conn, project: project, user: user} do
      {:ok, view, _html} = open(conn, project)
      view |> element(".rcollapse") |> render_click()
      assert has_element?(view, ".rail.open")
      assert Accounts.get_user!(user.id).rail_open
    end

    test "sets the user's theme", %{conn: conn, project: project, user: user} do
      Accounts.put_theme(user, "dark")
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#theme[data-theme=dark]")

      # dark -> system -> light
      view |> element("button[phx-click=theme]") |> render_click()
      assert has_element?(view, "#theme[data-theme=system]")
      assert Accounts.get_user!(user.id).theme == "system"
    end

    test "makes a new project and opens it", %{conn: conn, project: project, user: user} do
      {:ok, team} = Teams.create(Scope.for_user(user), %{"name" => "Ops"})
      {:ok, view, _html} = open(conn, project)

      view |> element("#new-project-btn") |> render_click()
      assert has_element?(view, "#new-project button[type=submit][disabled]")

      view
      |> element("#new-project-form")
      |> render_change(%{"project" => %{"name" => "Field notes"}})

      assert has_element?(view, "#np-slug", "slug: field_notes")
      view |> element("#new-project button.disc") |> render_click()
      assert has_element?(view, "#np-share option", "Ops")

      view
      |> element("#new-project-form")
      |> render_submit(%{
        "project" => %{"name" => "Field notes", "team_id" => to_string(team.id), "auth" => "open"}
      })

      made = Enum.find(Projects.list(Scope.for_user(user)), &(&1.name == "Field notes"))
      assert made.team_id == team.id and made.auth == "open"
      assert_redirect(view, ~p"/projects/#{made.id}")
    end
  end

  # The workspace opens its first chat (a new empty one when there is none).
  defp open(conn, project) do
    {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/projects/#{project.id}")
    assert to =~ ~r"^/projects/#{project.id}/c/[a-z0-9]+$"
    live(conn, to)
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
