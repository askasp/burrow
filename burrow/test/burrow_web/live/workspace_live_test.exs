defmodule BurrowWeb.WorkspaceLiveTest do
  use BurrowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures
  import Burrow.ProjectHelpers

  alias Burrow.Accounts.Scope
  alias Burrow.{Accounts, Chat, Chats, Projects, Runs, Secrets, Teams}

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
      assert has_element?(view, "#drawer .crow[data-on=true] .cdot.new")
      assert has_element?(view, "#drawer .crow .tt", "What should App do?")
      assert has_element?(view, ".pbar-name", "What should App do?")
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
    test "up to four open; closing an empty one deletes it", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)

      for _ <- 1..3, do: view |> element("#new-chat") |> render_click()
      assert length(Chats.list(project.id)) == 4
      assert has_element?(view, "#new-chat[disabled]")
      assert has_element?(view, "span[title='4 changes are open. Merge or discard one first.']")
      assert has_element?(view, "#drawer .dsec", "4 of 4")

      [first | _] = Chats.list(project.id)
      view |> element("#chat-#{first.id} .cx") |> render_click()
      assert_eventually(fn -> length(Chats.list(project.id)) == 3 end)
      refute has_element?(view, "#new-chat[disabled]")
    end

    test "the chat box picks the model; a new chat starts with it", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#model-pick option[selected]", "gpt-test")

      view |> element("#model-pick") |> render_change(%{"model" => "anthropic/claude-x"})
      assert [%{model: "anthropic/claude-x", effort: nil}] = Chats.list(project.id)

      assert has_element?(
               view,
               "#model-pick optgroup[label=anthropic] option[selected]",
               "claude-x"
             )

      view |> element("#new-chat") |> render_click()
      assert [_, %{model: "anthropic/claude-x"}] = Chats.list(project.id)
    end

    test "the thinking level changes by itself, keeping the model", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      view |> element("#model-pick") |> render_change(%{"model" => "anthropic/claude-x"})

      # The level's box sends only the level.
      render_hook(view, "pick_model", %{"_target" => ["effort"], "effort" => "low"})
      assert [%{model: "anthropic/claude-x"}] = Chats.list(project.id)
    end

    test "a disabled chat box sends no text", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)
      render_hook(view, "typing", %{"_target" => ["text"]})
      render_hook(view, "send", %{})
      assert has_element?(view, "#chat-input")
    end

    test "a landed change ships from its card, and its chat is done", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")
      run = Runs.start(project.id, "check", "main", change.id)
      Runs.finish(run, status: "passed")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert has_element?(view, "#chat-#{chat.id} .n", "##{change.id}")
      assert has_element?(view, ".pbar-name", "##{change.id}")
      assert has_element?(view, ".ws-cs h2", "Change ##{change.id}")
      # Without staging, main is what goes live: the chat box gives way, and
      # the chat is done, under Today.
      assert has_element?(view, "#chat-done", "##{change.id} is on main.")
      assert has_element?(view, "#chat-done", "This chat is done and has moved to Today.")
      assert has_element?(view, "#drawer .dday:has(#chat-#{chat.id}) .dsec", "Today")
      assert has_element?(view, "#chat-#{chat.id} .okic")
      assert has_element?(view, "#drawer .dnone", "Nothing open")
      refute has_element?(view, "#chat-input")
      # Its dev preview stays, to look into, until it is live.
      refute has_element?(view, ".vbar .seg button[disabled]", "dev")
      assert Burrow.Activity.unshipped?(project, chat.id)

      view |> element(".ws-cs button", "Ship") |> render_click()
      assert Totem.Repo.ref(Projects.repo_dir(project), "prod") == change.id
      assert has_element?(view, ".vbar .seg button[disabled]", "dev")
      refute Burrow.Activity.unshipped?(project, chat.id)

      # Live but not deployed yet, or down: the project bar says so.
      send(view.pid, {:env, "prod", down_env("prod")})
      assert has_element?(view, ".pbar-meta", "live — · no staging")
      assert has_element?(view, "#chat-done", "##{change.id} is live.")
      refute has_element?(view, "#chat-#{chat.id} .cdot")
      assert has_element?(view, "#chat-#{chat.id} .cs2", "live · ")
    end

    test "a done chat follows up in a new one, which starts from its change", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      view |> element("#chat-done button", "Follow up on ##{change.id}") |> render_click()

      follow = Enum.find(Chats.list(project.id), &(&1.id != chat.id))
      assert follow.follows == change.id
      assert_patch(view, ~p"/projects/#{project.id}/c/#{follow.id}")
      assert_push_event(view, "composer:focus", %{})
      assert has_element?(view, "#chat-#{follow.id}", "Follow-up to ##{change.id}")
      assert has_element?(view, ".ws-hello", "What should change next?")
      assert has_element?(view, "#composer .ctx", "follows ##{change.id} · Change lib/app.ex")

      # Peon gets the change's intent and the files it touched.
      instructions = Burrow.Agent.Prompt.instructions(project, follow.follows)
      assert instructions =~ "## This chat follows up on ##{change.id}"
      assert instructions =~ "on main: Change lib/app.ex\n"
      assert instructions =~ "\n- lib/app.ex\n"
      refute Burrow.Agent.Prompt.instructions(project) =~ "follows up"

      # The chip goes: the chat starts from scratch.
      view |> element("#composer .ctx button") |> render_click()
      refute has_element?(view, "#composer .ctx")
      refute has_element?(view, "#chat-#{follow.id}", "Follow-up")
      assert Chats.get(follow.id).follows == nil

      # With four open chats there is no room for another; done ones don't count.
      for _ <- 1..3, do: Chats.create_empty(project.id, "aksel")
      render_patch(view, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert has_element?(view, "#chat-done button[disabled]", "New chat")
      assert has_element?(view, "#chat-done button[disabled]", "Follow up on ##{change.id}")
    end

    test "closing the open chat opens the one above it, or a new one", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")

      view |> element("#chat-done button", "New chat") |> render_click()
      fresh = Enum.find(Chats.list(project.id), &(&1.id != chat.id))
      assert_patch(view, ~p"/projects/#{project.id}/c/#{fresh.id}")
      view |> element("#new-chat") |> render_click()
      newer = Enum.find(Chats.list(project.id), &(&1.id not in [chat.id, fresh.id]))
      assert_patch(view, ~p"/projects/#{project.id}/c/#{newer.id}")

      # Open chats close, the open one with prefix q; done ones stay.
      assert has_element?(view, "#chat-#{fresh.id} .cx")
      assert has_element?(view, "#chat-#{newer.id} .cx[data-kb-key=q]")
      refute has_element?(view, "#chat-#{chat.id} .cx")

      view |> element("#chat-#{newer.id} .cx") |> render_click()
      assert_patch(view, ~p"/projects/#{project.id}/c/#{fresh.id}")

      view |> element("#chat-#{fresh.id} .cx") |> render_click()
      assert_eventually(fn -> length(Chats.list(project.id)) == 2 end)
      last = Enum.find(Chats.list(project.id), &(&1.id != chat.id))
      assert last.started_at == nil and last.id not in [fresh.id, newer.id]
      assert_patch(view, ~p"/projects/#{project.id}/c/#{last.id}")
    end

    test "main failing its check shows", %{conn: conn, project: project} do
      run = Runs.start(project.id, "check", "main", 1)
      Runs.finish(run, status: "failed", detail: "boot failed")

      {:ok, view, _html} = open(conn, project)
      assert render(view) =~ "Main #1 did not pass in prod mode"
    end
  end

  describe "the queue and the goal" do
    test "Queue puts the box's text in the chat's queue; only unstarted tickets go", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      [chat] = Chats.list(project.id)
      refute has_element?(view, "#queue")

      for text <- ["Make the logo bigger", "Add a footer"],
          do: view |> element("#composer") |> render_submit(%{"text" => text, "to" => "queue"})

      assert has_element?(view, "#queue .qrow", "Make the logo bigger")
      assert has_element?(view, "#queue summary", "2 to do")
      # The box empties from the server: with images, the browser sends the
      # text only after they are up.
      assert_push_event(view, "composer:put", %{text: ""})
      # The agent isn't working, so the queue can be started from here.
      assert has_element?(view, "#work-queue")
      # Nothing went to the agent: the chat hasn't started.
      assert [%{started_at: nil}] = Chats.list(project.id)

      [logo, footer] = Enum.sort_by(Chat.tickets(project, chat.id), & &1.title, :desc)
      file = Path.join(Chat.tickets_dir(project, chat.id), "#{footer.id}.md")
      File.write!(file, String.replace(File.read!(file), "status: open", "status: in_progress"))
      send(view.pid, {:tickets, Chat.tickets(project, chat.id)})

      refute has_element?(view, "#ticket-#{footer.id} .cx")
      view |> element("#ticket-#{logo.id} .cx") |> render_click()
      assert [%{id: id, status: "in_progress"}] = Chat.tickets(project, chat.id)
      assert id == footer.id
      refute has_element?(view, "#ticket-#{logo.id}")
    end

    test "the chat's goal shows in the box until it is dropped", %{conn: conn, project: project} do
      {:ok, _view, _html} = open(conn, project)
      [chat] = Chats.list(project.id)
      Chats.set(chat, goal: "the tests pass")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert has_element?(view, "#goal-chip", "Goal: the tests pass")

      view |> element("#goal-chip .cx") |> render_click()
      refute has_element?(view, "#goal-chip")
      assert Chats.get(chat.id).goal == nil
    end
  end

  describe "the design view" do
    test "shows main's boards by folder; one opens full size and goes to the chat box", %{
      conn: conn,
      project: project
    } do
      other = Chats.create(project.id, "Takes", "aksel")
      land!(project, other, "design/settings/a.html", "<title>tabs</title>")

      {:ok, view, _html} = open(conn, project)
      view |> element("#design-view") |> render_click()
      assert has_element?(view, ".dgroup .gname", "settings/")
      assert has_element?(view, ".thumb .cap", "tabs")
      assert has_element?(view, ".thumb .btag.main")

      view |> element(".thumb .hit") |> render_click()
      assert has_element?(view, "#board-full iframe[sandbox]")

      view |> element(".fullbar button", "Build this") |> render_click()
      assert_push_event(view, "composer:put", %{text: "Build design/settings/a.html"})

      view |> element(".fullbar button", "Boards") |> render_click()
      assert has_element?(view, ".thumbs")
    end

    test "no boards yet: the peon naps by its easel", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)
      view |> element("#design-view") |> render_click()
      assert has_element?(view, ".dempty #easel-idle")

      view |> element(".chipq", "Draw 3 takes") |> render_click()
      assert_push_event(view, "composer:put", %{text: "Draw 3 takes on the home page"})
    end

    test "a board whose script fails says so, and Peon is asked to fix it", %{
      conn: conn,
      project: project
    } do
      other = Chats.create(project.id, "Takes", "aksel")
      land!(project, other, "design/c.html", "<script>tokens.x</script>")
      [board] = Burrow.Design.boards(project, other.id)

      {:ok, view, _html} = open(conn, project)
      view |> element("#design-view") |> render_click()

      render_hook(view, "board_error", %{
        "path" => "design/c.html",
        "hash" => board.hash,
        "error" => "ReferenceError: tokens is not defined (c.html:1)"
      })

      assert has_element?(view, ".thumb.bad .errbox", "tokens is not defined")
      view |> element(".errbox button") |> render_click()

      assert_push_event(view, "composer:put", %{
        text:
          "design/c.html does not load (ReferenceError: tokens is not defined (c.html:1)). Fix it."
      })
    end

    test "a chat's boards alone are submitted from their card and never ship", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Takes", "aksel")
      repo = Projects.repo_dir(project)
      dir = Burrow.Chat.workspace_dir(project, chat.id)
      Burrow.Workspace.reset(repo, dir, Totem.Repo.ref(repo, "main"))
      File.mkdir_p!(Path.join(dir, "design"))
      File.write!(Path.join(dir, "design/a.html"), "<title>a</title>")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      render_async(view)
      assert has_element?(view, "#design-view .dcnt", "1")
      assert has_element?(view, ".ws-cs .ptag", "design only")

      view |> element("#submit-design") |> render_click()
      assert Totem.Repo.file(repo, "design/a.html") == {:ok, "<title>a</title>"}
      assert has_element?(view, ".ws-cs", "On main, so teammates see the boards")
      assert has_element?(view, "#chat-#{chat.id} .cdot.done")
      refute has_element?(view, "#chat-input[disabled]")
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

  describe "the drawer" do
    test "switches to the user's projects, and new ones as they come", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, other} = Projects.create(Scope.for_user(user), %{"name" => "Sauna Booking"})

      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#project-switch .nm", "App")
      assert has_element?(view, "#project-menu .pmrow[aria-current=page]", "App")
      # Cells don't run in tests, so it shows as stopped.
      assert has_element?(
               view,
               "#project-menu a.pmrow[href='/projects/#{other.id}'] .rhp.stopped"
             )

      refute has_element?(view, "#drawer.closed")

      {:ok, third} = Projects.create(Scope.for_user(user), %{"name" => "Stash"})

      assert_eventually(fn ->
        has_element?(view, "#project-menu a.pmrow[href='/projects/#{third.id}']")
      end)
    end

    test "collapses, and the user's choice is kept", %{conn: conn, project: project, user: user} do
      {:ok, view, _html} = open(conn, project)
      view |> element("#drawer .dhide") |> render_click()
      assert has_element?(view, "#drawer.closed")
      assert Accounts.get_user!(user.id).chats_collapsed
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

      # A repo's token goes in with it.
      refute has_element?(view, "#np-token")

      view
      |> element("#new-project-form")
      |> render_change(%{"project" => %{"repo_url" => "https://github.com/a/b.git"}})

      assert has_element?(view, "#np-token[type=password]")

      view
      |> element("#new-project-form")
      |> render_change(%{"project" => %{"repo_url" => ""}})

      view
      |> element("#new-project-form")
      |> render_submit(%{
        "project" => %{"name" => "Field notes", "team_id" => to_string(team.id), "auth" => "open"}
      })

      made = Enum.find(Projects.list(Scope.for_user(user)), &(&1.name == "Field notes"))
      assert made.team_id == team.id and made.auth == "open"
      assert_redirect(view, ~p"/projects/#{made.id}")
    end

    test "a new app with accounts can let anyone sign up", %{conn: conn, project: project} do
      Phoenix.PubSub.subscribe(Burrow.PubSub, "projects")
      {:ok, view, _html} = open(conn, project)

      view |> element("#new-project-btn") |> render_click()
      view |> element("#new-project button.disc") |> render_click()

      # Off unless picked: the first account is the admin and adds the others.
      assert has_element?(view, "#np-signups:not([checked])")
      assert has_element?(view, "#np-signups-hint", "adds everyone else")

      form = element(view, "#new-project-form")
      render_change(form, %{"project" => %{"auth" => "basic"}})
      refute has_element?(view, "#np-signups")

      render_change(form, %{"project" => %{"auth" => "accounts", "signups" => "true"}})
      assert has_element?(view, "#np-signups[checked]")
      assert has_element?(view, "#np-signups-hint", "anyone can make an account")

      render_submit(form, %{"project" => %{"name" => "Club", "signups" => "true"}})

      # Handed to the new app (`Burrow.Bootstrap`), not stored.
      assert_receive {:project_created, %{name: "Club", auth: "accounts", signups: true}}
    end
  end

  # An env as Burrow.Env.info/2 has it when it runs nothing.
  defp down_env(name),
    do: %{
      name: name,
      status: :stopped,
      attach: "",
      good: nil,
      usage: %{history: [], errors: 0, sessions: 0, p95: nil, visitors: 0, rpm: 0},
      stats: nil,
      errors: [],
      url: "https://#{name}.test",
      deployed: nil,
      deploy: nil
    }

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
