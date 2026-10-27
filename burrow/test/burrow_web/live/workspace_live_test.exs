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
      assert has_element?(view, ".pbar-meta", "app · New chat")
      assert has_element?(view, "#more-menu .menu-meta", "app · staging — · prod —")
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

    test "once up, opens what was asked for, such as a new chat", %{conn: conn, user: user} do
      {:ok, other} = Projects.create(Scope.for_user(user), %{"name" => "Later"})
      {:ok, view, _html} = live(conn, ~p"/projects/#{other.id}/c/new")

      Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, other.id, :running})
      assert_redirect(view, ~p"/projects/#{other.id}/c/new")
    end

    test "is only for those who can open the project", %{project: project} do
      stranger = user_fixture()
      conn = log_in_user(build_conn(), stranger)
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/projects/#{project.id}") end
    end

    test "in a shared project everyone sees only their own chats", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, _view, _html} = open(conn, project)
      [mine] = Chats.list(project.id)

      owner = Scope.for_user(user)
      mate = user_fixture()
      {:ok, team} = Teams.create(owner, %{"name" => "Crew"})
      {:ok, _} = Teams.add_member(owner, team, mate.email)
      {:ok, _} = Projects.share(owner, project, team.id)

      mate_conn = log_in_user(build_conn(), mate)
      {:ok, view, _html} = open(mate_conn, project)
      [theirs] = Chats.list(project, mate.id)
      assert has_element?(view, "#chat-#{theirs.id}")
      refute has_element?(view, "#chat-#{mine.id}")

      # Not by its address either, nor its images.
      base = ~p"/projects/#{project.id}"
      assert {:error, {:live_redirect, %{to: ^base}}} = live(mate_conn, "#{base}/c/#{mine.id}")
      assert get(mate_conn, "#{base}/c/#{mine.id}/images/a.png").status == 404

      {:ok, view, _html} = live(conn, "#{base}/c/#{mine.id}")
      refute has_element?(view, "#chat-#{theirs.id}")
    end

    test "the preview shows the app as a phone, or full width", %{conn: conn, project: project} do
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#phone-btn[aria-pressed=false][aria-label='Show as phone']")
      refute has_element?(view, ".ws-prev-body.phone")

      view |> element("#phone-btn") |> render_click()
      assert has_element?(view, "#phone-btn[aria-pressed=true][aria-label='Show full width']")
      assert has_element?(view, ".ws-prev-body.phone")

      # The design view has its own boards, not the app.
      view |> element("#design-view") |> render_click()
      refute has_element?(view, "#phone-btn")

      # The other versions keep it.
      view |> element("#view-menu button", "staging") |> render_click()
      assert has_element?(view, ".ws-prev-body.phone")

      view |> element("#phone-btn") |> render_click()
      assert has_element?(view, "#phone-btn[aria-pressed=false]")
      refute has_element?(view, ".ws-prev-body.phone")
    end
  end

  describe "chats" do
    test "New chat never blocks: one empty chat, however many are open", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      [empty] = Chats.list(project.id)

      # The empty chat it opened on is the new chat.
      for _ <- 1..2, do: view |> element("#new-chat") |> render_click()
      assert [^empty] = Chats.list(project.id)

      for _ <- 1..5, do: Chats.create(project.id, "Busy", user)
      refute has_element?(view, "#new-chat[disabled]")
      view |> element("#new-chat") |> render_click()
      assert_patched(view, ~p"/projects/#{project.id}/c/#{empty.id}")

      # Closing an empty chat deletes it.
      assert has_element?(view, "#drawer-edit")
      view |> element("#chat-#{empty.id} .cx") |> render_click()
      assert_eventually(fn -> length(Chats.list(project.id)) == 5 end)
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

      # The open chat is still empty, so New chat stays on it.
      view |> element("#new-chat") |> render_click()
      assert [chat] = Chats.list(project.id)

      started!(view, chat)
      view |> element("#new-chat") |> render_click()
      assert [_, %{model: "anthropic/claude-x"}] = Chats.list(project.id)
    end

    test "the chat box picks the agent; Design shows the boards, a new chat builds", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#agent-pick option[selected]", "Build")
      assert has_element?(view, "#agent-pick option", "Design")

      view |> element("#agent-pick") |> render_change(%{"agent" => "design"})
      assert [%{agent: "design"}] = Chats.list(project.id)
      assert has_element?(view, "#agent-pick option[selected]", "Design")
      assert render(view) =~ "hero-swatch"

      view |> element("#agent-pick") |> render_change(%{"agent" => "nope"})
      assert [%{agent: "design"}] = Chats.list(project.id)

      started!(view, hd(Chats.list(project.id)))
      view |> element("#new-chat") |> render_click()
      assert project.id |> Chats.list() |> Enum.map(& &1.agent) |> Enum.sort() == [nil, "design"]
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

    test "a change on staging ships from its card, and its chat is done", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")

      # Merged, main runs its check: the chat goes on until staging has it.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert has_element?(view, ".pbar-meta", "##{change.id} going to staging")
      refute has_element?(view, "#chat-done")

      stage!(project, change.id)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")
      assert has_element?(view, "#chat-#{chat.id} .cm", "##{change.id}")
      assert has_element?(view, ".pbar-meta", "##{change.id} on staging")
      assert has_element?(view, ".ws-cs h2", "Change ##{change.id}")
      # On staging the chat box gives way, and the chat is done; it stays
      # under Today. Shipping to prod is the project's.
      assert has_element?(view, "#chat-done", "##{change.id} is on staging.")
      assert has_element?(view, "#chat-done", "This chat is done.")
      assert has_element?(view, "#drawer .dday:has(#chat-#{chat.id}) .dsec", "Today")
      assert has_element?(view, "#chat-#{chat.id} .okic")
      refute has_element?(view, "#drawer-edit")
      refute has_element?(view, "#chat-input")
      # Its dev preview stays, to look into, until it is on prod.
      refute has_element?(view, "#view-menu button[disabled]", "dev")
      assert Burrow.Activity.unshipped?(project, chat.id)

      view |> element(".ws-cs button", "Ship") |> render_click()
      assert Totem.Repo.ref(Projects.repo_dir(project), "prod") == change.id
      assert has_element?(view, "#view-menu button[disabled]", "dev")
      refute Burrow.Activity.unshipped?(project, chat.id)

      # On prod but not deployed yet, or down: the project's line says so.
      send(view.pid, {:env, "prod", env_info("prod", nil)})
      assert has_element?(view, "#more-menu .menu-meta", "staging ##{change.id} · prod —")
      assert has_element?(view, "#chat-done", "##{change.id} is on prod.")
      refute has_element?(view, "#chat-#{chat.id} .cdot")
      assert has_element?(view, "#chat-#{chat.id} .cst", "On prod")
    end

    test "a done chat follows up in a new one, which starts from its change", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")
      stage!(project, change.id)

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
      assert instructions =~ "## Long commands"
      refute Burrow.Agent.Prompt.instructions(project) =~ "follows up"

      # The chip goes: the chat starts from scratch.
      view |> element("#composer .ctx button") |> render_click()
      refute has_element?(view, "#composer .ctx")
      refute has_element?(view, "#chat-#{follow.id}", "Follow-up")
      assert Chats.get(follow.id).follows == nil

      # Open chats don't block a new one.
      for _ <- 1..4, do: Chats.create(project.id, "Busy", "aksel")
      render_patch(view, ~p"/projects/#{project.id}/c/#{chat.id}")
      refute has_element?(view, "#chat-done button[disabled]")
    end

    test "closing the open chat opens the one above it, or a new one", %{
      conn: conn,
      project: project
    } do
      chat = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")
      stage!(project, change.id)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat.id}")

      view |> element("#chat-done button", "New chat") |> render_click()
      fresh = Enum.find(Chats.list(project.id), &(&1.id != chat.id))
      assert_patch(view, ~p"/projects/#{project.id}/c/#{fresh.id}")
      started!(view, fresh)
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
      assert has_element?(view, "#queue-link", "2 next")
      assert has_element?(view, "#queue .qtop", "2 to do")
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

      view |> element("#queue-add-form") |> render_submit(%{"text" => "Add a header"})
      assert has_element?(view, "#queue .qrow", "Add a header")
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

    test "boards picked in the grid build together", %{conn: conn, project: project} do
      other = Chats.create(project.id, "Pages", "aksel")
      land!(project, other, "design/home.html", "<title>home</title>")
      land!(project, other, "design/list.html", "<title>list</title>")
      land!(project, other, "design/info.html", "<title>info</title>")

      {:ok, view, _html} = open(conn, project)
      view |> element("#design-view") |> render_click()
      assert has_element?(view, "#build-boards[disabled]", "Build")

      pick =
        &(view
          |> element(".tpick[aria-label='Pick design/#{&1}.html to build']")
          |> render_click())

      pick.("list")
      pick.("home")
      assert has_element?(view, ".thumb.picked .tpick[aria-checked=true]")
      assert has_element?(view, "#build-boards", "Build 2 boards")

      view |> element("#build-boards") |> render_click()

      assert_push_event(view, "composer:put", %{
        text: "Build these boards: design/home.html, design/list.html"
      })

      refute has_element?(view, ".tpick[aria-checked=true]")

      view |> element(".dpick button", "Pick all") |> render_click()
      assert has_element?(view, "#build-boards", "Build 3 boards")
      view |> element(".dpick button", "Pick none") |> render_click()
      assert has_element?(view, "#build-boards[disabled]")
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
      assert has_element?(view, "#design-view .vd", "1 changed")
      assert has_element?(view, ".ws-cs .ptag", "design only")

      view |> element("#submit-design") |> render_click()
      assert Totem.Repo.file(repo, "design/a.html") == {:ok, "<title>a</title>"}
      assert has_element?(view, ".ws-cs", "Merged, so teammates see the boards")
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
      {:ok, view, _html} = open(conn, project)
      refute has_element?(view, "#overview")
      view |> element("#overview-btn") |> render_click()
      assert has_element?(view, "#overview-btn", "Back to preview")
      assert has_element?(view, "#overview .env .eyebrow", "staging")
      refute has_element?(view, ".vbar")

      view |> element("#auto-ship") |> render_click()

      assert Projects.settings(project) |> Map.take(["auto_ship", "auto_ship_by"]) ==
               %{"auto_ship" => true, "auto_ship_by" => user.email}

      assert render(view) =~ "Every change that passes ships by itself"

      view |> element("#overview button", "Back to preview") |> render_click()
      assert has_element?(view, "#view-menu button", "staging")
    end

    test "the projects page's menu opens deploys and usage here", %{conn: conn, project: project} do
      {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/projects/#{project.id}?open=deploys")
      assert to =~ ~r"^/projects/#{project.id}/c/[a-z0-9]+\?open=deploys$"
      {:ok, view, _html} = live(conn, to)
      assert has_element?(view, "#overview-btn", "Back to preview")
      assert has_element?(view, "#overview .env .eyebrow", "staging")
    end

    test "staging shows in the pane; prod only opens in a new tab", %{
      conn: conn,
      project: project
    } do
      stage!(project, 1)
      {:ok, view, _html} = open(conn, project)
      refute has_element?(view, "#view-prod")

      view |> element("#view-menu button", "staging") |> render_click()
      assert has_element?(view, "iframe.ws-frame[src='https://staging.test']")

      send(view.pid, {:env, "prod", env_info("prod", 1)})
      assert has_element?(view, "#view-prod[href='https://prod.test'][target=_blank]")
    end
  end

  describe "an internal app" do
    setup %{user: user, tmp_dir: dir} do
      {:ok, ops} = Projects.create(Scope.for_user(user), %{"name" => "Ops", "auth" => "burrow"})
      %{ops: start_project!(ops, dir)}
    end

    test "goes dev, then live: no staging, no prod, no Ship; live shows through Burrow", %{
      conn: conn,
      ops: ops
    } do
      chat = Chats.create(ops.id, "Say hello", "aksel")
      change = land!(ops, chat, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")

      {:ok, view, _html} = live(conn, ~p"/projects/#{ops.id}/c/#{chat.id}")
      assert has_element?(view, ".pbar-meta", "##{change.id} going live")
      assert has_element?(view, ".ws-cs .flow", "live")
      refute has_element?(view, ".ws-cs .flow", "staging")
      assert has_element?(view, "#more-menu .menu-meta", "ops · live —")

      repo = Projects.repo_dir(ops)
      :ok = Totem.Repo.move_ref(repo, "live", change.id, nil)
      start_supervised!({Burrow.FakeEnv, {ops.id, "live", env_info("live", change.id)}})

      {:ok, view, _html} = live(conn, ~p"/projects/#{ops.id}/c/#{chat.id}")
      assert has_element?(view, "#chat-done", "##{change.id} is live.")
      assert has_element?(view, "#chat-#{chat.id} .cst", "Live")
      refute has_element?(view, ".ws-cs button", "Ship")
      refute has_element?(view, "#view-prod")

      view |> element("#view-menu button", "live") |> render_click()
      assert has_element?(view, "iframe.ws-frame[src='/projects/#{ops.id}/app']")

      view |> element("#overview-btn") |> render_click()
      assert has_element?(view, "#overview .env .eyebrow", "live")
      refute has_element?(view, "#auto-ship")
    end

    test "opens full size from the drawer's apps", %{conn: conn, ops: ops, project: project} do
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#apps a#app-#{ops.id}[href='/apps/#{ops.id}']", "Ops")
      refute has_element?(view, "#apps a#app-#{project.id}")

      {:ok, app, _html} = live(conn, ~p"/apps/#{ops.id}")
      assert has_element?(app, "#app-#{ops.id}[aria-current=page]")
      assert has_element?(app, "#peek .nm", "Ops")
      assert has_element?(app, ".ws-prev-empty", "Not live yet")

      send(app.pid, {:env, "live", env_info("live", 2)})
      assert has_element?(app, "iframe.ws-frame[src='/projects/#{ops.id}/app']")
    end

    test "a project that isn't internal has no app page", %{conn: conn, project: project} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/apps/#{project.id}")
      assert to == ~p"/projects/#{project.id}"
    end
  end

  describe "a horde" do
    test "the + menu splits big tasks into a horde, this many peons at once", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      refute has_element?(view, "#horde-chip")
      view |> element("#horde-on") |> render_click()
      assert has_element?(view, "#horde-chip", "Horde · 4")
      view |> element("#horde-pick button[aria-label='More at once']") |> render_click()
      assert has_element?(view, "#horde-chip", "Horde · 5")
      assert has_element?(view, "#horde-pick", "Guardrails")
      view |> element("#horde-on") |> render_click()
      refute has_element?(view, "#horde-chip")
    end

    test "/horde is in the / menu of a new chat, before its agent runs", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      view |> form("#composer", %{"text" => "/"}) |> render_change()
      assert has_element?(view, "#slash-menu", "/goal")
      view |> form("#composer", %{"text" => "/ho"}) |> render_change()
      assert has_element?(view, "#slash-menu .slash-item", "/horde")
      refute has_element?(view, "#slash-menu", "/goal")
      view |> element("#slash-menu button", "/horde") |> render_click()
      refute has_element?(view, "#slash-menu")
    end

    test "the queue runs as a horde: a tile per ticket, the blocked ones wait", %{
      conn: conn,
      project: project,
      user: user
    } do
      lead = Chats.create(project.id, "Capitalize", user)
      dir = Chat.tickets_dir(project, lead.id)
      {:ok, a} = Burrow.Tickets.create(dir, "Do a", "Capitalize lib/a.ex")
      {:ok, _b} = Burrow.Tickets.create(dir, "Do b", "Capitalize lib/b.ex")
      tk(dir, ["dep", Enum.at(Burrow.Tickets.list(dir), 1).id, a])
      Chats.pick_horde(lead, 1)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{lead.id}")
      assert has_element?(view, "#horde-queue", "2 tk tickets · 2 waves")
      assert has_element?(view, "#horde-queue .htasks", "after #{a}")

      view |> element("#horde-start") |> render_click()
      render_async(view)
      refute has_element?(view, "#horde-queue")
      assert has_element?(view, "#horde #peon-1.s-work")
      assert has_element?(view, "#horde #peon-2.s-block")
      assert has_element?(view, "#horde-bar", "1 working")
      assert has_element?(view, "#drawer", "Horde · 0/2 shipped")
      # The peons' chats stay out of the drawer.
      refute has_element?(view, "#drawer", "Do a")

      view |> element("#peon-2") |> render_click()
      assert has_element?(view, "#peon-detail", "Blocked.")
      assert has_element?(view, "#peon-detail .trows", "Do a")
      assert has_element?(view, "#horde #peon-1.dep")

      view |> element("#peon-1") |> render_click()
      assert has_element?(view, "#peon-detail h2", a)
      assert has_element?(view, "#peon-detail .ptask", "Capitalize lib/a.ex")

      # A peon's chat opens from the horde; the drawer still marks the horde's chat.
      view |> element("#peon-detail a", "Open its chat") |> render_click()
      assert has_element?(view, "#peon-of", "Back to the horde")
      refute has_element?(view, "#drawer", "Do a")
      assert has_element?(view, "#drawer .crow[data-on=true]", "Capitalize")
      view |> element("#peon-of a", "Back to the horde") |> render_click()
      view |> element("#peon-1") |> render_click()
      view |> element("#peon-detail button", "Stop this peon") |> render_click()
      assert has_element?(view, "#peon-detail", "Skipped")
      # Skipped, it lets what waits on it go ahead.
      assert has_element?(view, "#horde #peon-2.s-work")

      view |> element("#horde-stop") |> render_click()
      view |> element("#stop-horde button", "Stop, keep what shipped") |> render_click()
      assert has_element?(view, "#horde-stopped")
      refute has_element?(view, "#horde-bar")
    end

    test "its changes, and errors after a ship that pause it", %{
      conn: conn,
      project: project,
      user: user
    } do
      lead = Chats.create(project.id, "Capitalize", user)
      tasks = [%{"title" => "Do a", "task" => "a"}, %{"title" => "Do b", "task" => "b"}]
      {:ok, horde} = Burrow.Hordes.plan(project, lead.id, tasks, 2)
      horde = Burrow.Hordes.start(project, horde)
      first = Enum.find(horde.peons, &(&1.n == 1))

      change =
        land!(project, Chats.get(first.chat_id), "lib/app.ex", "defmodule App do :ok end\n")

      Burrow.Hordes.drafted(project, first.chat_id, "landed")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{lead.id}")
      view |> element("#horde button", "See the changes") |> render_click()
      assert has_element?(view, "#horde-changes .cch", "##{change.id}")
      assert has_element?(view, "#horde-changes .cfile", "lib/app.ex")
      view |> element("#horde-changes button", "Horde") |> render_click()
      refute has_element?(view, "#horde-changes")

      incident =
        Burrow.Repo.insert!(%Burrow.Incidents{
          project_id: project.id,
          env: "staging",
          fingerprint: "boom",
          title: "RuntimeError: boom",
          change_id: change.id,
          last_seen_at: DateTime.utc_now(:second)
        })

      # A stuck peon retries on another model.
      Burrow.Hordes.idle(project, Enum.find(horde.peons, &(&1.n == 2)).chat_id)
      view |> element("#horde-stuck button", "Help it") |> render_click()
      assert has_element?(view, "#peon-detail", "Stopped without shipping")

      view
      |> form("#bigger-form", %{"model" => "openai/gpt-test"})
      |> render_submit()

      peon = Enum.find(Burrow.Hordes.get!(horde.id).peons, &(&1.n == 2))
      assert peon.status == "working"
      assert Chats.get(peon.chat_id).model == "openai/gpt-test"

      Burrow.Hordes.errors(project, incident)
      assert has_element?(view, "#horde-errors", "RuntimeError: boom")
      assert has_element?(view, "#horde-errors button", "Revert ##{change.id} now")
      view |> element("#horde-errors button", "Resume anyway") |> render_click()
      refute has_element?(view, "#horde-errors")
    end
  end

  describe "shipping" do
    test "the + menu picks review; a passed change then waits for Merge", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      refute has_element?(view, "#shipping-chip")
      view |> element("#shipping-pick button", "Review") |> render_click()
      assert has_element?(view, "#shipping-chip", "Review")
      assert has_element?(view, "#shipping-pick button[aria-checked=true]", "Review")

      chat_id = view |> render() |> then(&Regex.run(~r"/c/([a-z0-9]+)", &1)) |> List.last()
      repo = Projects.repo_dir(project)
      Burrow.Workspace.reset(repo, Chat.workspace_dir(project, chat_id), 1)

      {:ok, _} =
        Totem.Repo.put_draft(repo, chat_id, Totem.Repo.ref(repo, "main"), [{"lib/x.ex", "x"}],
          intent: "Add x"
        )

      Totem.Repo.update_draft(repo, chat_id, status: "held")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{chat_id}")
      assert has_element?(view, ".ws-cs .st", "ready to merge")
      view |> element("#merge-btn") |> render_click()
      assert render(view) =~ "Merged as #2."
      assert Totem.Repo.ref(repo, "main") == 2
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
      assert has_element?(view, "#drawer .dswitch .swt[aria-current=true]", "App")
      # Cells don't run in tests, so it shows as stopped.
      assert has_element?(view, "#drawer .dswitch #switch-#{other.id} .rhp.stopped")

      refute has_element?(view, "#drawer.closed")

      {:ok, third} = Projects.create(Scope.for_user(user), %{"name" => "Stash"})

      assert_eventually(fn ->
        has_element?(view, "#drawer .dswitch #switch-#{third.id}")
      end)
    end

    test "lists the chats by when they were worked on, and opens on the last", %{
      conn: conn,
      project: project
    } do
      older = Chats.create(project.id, "Older", "aksel")
      week = Chats.create(project.id, "This week", "aksel")
      yesterday = Chats.create(project.id, "Yesterday", "aksel")
      earlier = Chats.create(project.id, "Earlier today", "aksel")
      last = Chats.create(project.id, "Last", "aksel")
      worked!(project, older, -24 * 30)
      worked!(project, week, -24 * 3)
      worked!(project, yesterday, -24)
      worked!(project, earlier, -1)
      worked!(project, last, 0)

      {:ok, view, html} = open(conn, project)
      assert has_element?(view, "#chat-#{last.id}[data-on=true]")
      assert has_element?(view, "#day-today .dsec #drawer-edit")
      assert has_element?(view, "#day-today #chat-#{last.id}")
      assert has_element?(view, "#day-yesterday #chat-#{yesterday.id}")
      assert has_element?(view, "#day-this-week #chat-#{week.id}")
      assert has_element?(view, "#day-older #chat-#{older.id}")
      assert order(html) == Enum.map([last, earlier, yesterday, week, older], & &1.id)

      # A message puts its chat on top.
      Chats.started(Chats.get(yesterday.id), "Once more")
      worked!(project, last, -1 / 60)
      {:ok, _view, html} = open(conn, project)
      assert hd(order(html)) == yesterday.id
    end

    test "a day before today folds to its open chats, and stays folded", %{
      conn: conn,
      project: project,
      user: user
    } do
      done = Chats.create(project.id, "Say hello", "aksel")
      change = land!(project, done, "lib/app.ex", "defmodule App do def hi, do: :hi end\n")
      stage!(project, change.id)
      open = Chats.create(project.id, "Still open", "aksel")
      worked!(project, done, -24)
      worked!(project, open, -24)

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/c/#{Chats.create_empty(project.id, "aksel").id}")

      refute has_element?(view, "#day-today .dfold")
      view |> element("#day-yesterday .dfold", "Yesterday") |> render_click()
      assert has_element?(view, "#day-yesterday.folded .dfold[aria-expanded=false]", "1 done")
      assert Accounts.get_user!(user.id).folded_days == ["Yesterday"]

      # Folded, the done chat hides (CSS) unless it is the one shown.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/c/#{done.id}")
      assert has_element?(view, "#day-yesterday.folded #chat-#{done.id}.past[data-on=true]")
      assert has_element?(view, "#day-yesterday.folded #chat-#{open.id}:not(.past)")

      view |> element("#day-yesterday .dfold") |> render_click()
      refute has_element?(view, "#day-yesterday.folded")
      assert Accounts.get_user!(user.id).folded_days == []
    end

    test "opens from the rail; the place on top switches to Chats or a project", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, ".rail button[data-kb-key=h]")
      assert has_element?(view, "#project-switch", "App")
      assert has_element?(view, "#chat-search[placeholder='Search App']")
      assert has_element?(view, "#drawer .dswitch #switch-chats", "Chats")
      assert has_element?(view, "#drawer .dswitch a[href='/projects']", "All projects")
      assert has_element?(view, "#drawer .dswitch #new-project-btn", "New project")
      assert has_element?(view, "#drawer .dhome a[href='/projects']", "All projects")
      assert has_element?(view, ".rail a[href='/projects'][aria-label='All projects']")
    end

    test "picking another place lists its chats, each a way into it", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, other} = Projects.create(Scope.for_user(user), %{"name" => "Stash"})
      chat = Chats.create(other.id, "Count the jars", user)
      {:ok, view, _html} = open(conn, project)

      view |> element("#switch-#{other.id}") |> render_click()
      assert has_element?(view, "#peek-switch", "Stash")
      assert has_element?(view, "#peek-search[placeholder='Search Stash']")
      assert has_element?(view, "#peek-#{chat.id} a[href='/projects/#{other.id}/c/#{chat.id}']")
      assert has_element?(view, "#peek-new[href='/projects/#{other.id}/c/new']")
      assert has_element?(view, "#switch-#{other.id}[aria-current=true]")
      refute has_element?(view, "#chat-search")

      # This project again: its own chats.
      view |> element("#switch-#{project.id}") |> render_click()
      refute has_element?(view, "#peek")
      assert has_element?(view, "#chat-search[placeholder='Search App']")

      # /c/new, New chat there from another page, opens an empty chat.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/projects/#{project.id}/c/new")
      assert to =~ ~r"^/projects/#{project.id}/c/[a-z0-9]+$"
    end

    test "the account menu holds teams, logins, the theme and log out", %{
      conn: conn,
      project: project,
      user: user
    } do
      Accounts.put_theme(user, "dark")
      {:ok, view, _html} = open(conn, project)
      assert has_element?(view, "#theme[data-theme=dark]")
      assert has_element?(view, "#account-btn", user.email)

      for {href, text} <- [
            {"/teams", "Teams"},
            {"/ai", "AI login"},
            {"/logins", "Logins"},
            {"/users/settings", "Email and password"},
            {"/users/log-out", "Log out"}
          ],
          do: assert(has_element?(view, "#account-pop a[href='#{href}']", text))

      # The theme posts to /users/theme (BurrowWeb.ThemeController)
      assert has_element?(
               view,
               "#account-pop form[action='/users/theme'] button[aria-pressed=true]",
               "Dark"
             )

      assert has_element?(view, "#account-pop button[name=theme][value=system]", "System")
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

  # The workspace opens its first chat (a new empty one when there is none).
  # The chat was worked on `hours` from now (negative: ago), and so was its draft.
  defp worked!(project, chat, hours) do
    at = DateTime.utc_now(:second) |> DateTime.add(round(hours * 3600), :second)
    Chats.set(chat, updated_at: at)
    path = Path.join([Projects.repo_dir(project), "drafts", chat.id <> ".json"])

    with {:ok, json} <- File.read(path),
         do:
           File.write!(
             path,
             JSON.encode!(%{JSON.decode!(json) | "at" => DateTime.to_iso8601(at)})
           )
  end

  # The chat ids in the drawer, top to bottom.
  defp order(html),
    do:
      Regex.scan(~r/id="chat-([a-z0-9]+)" class="crow/, html, capture: :all_but_first)
      |> List.flatten()

  # The chat had its first message, without starting an agent.
  defp started!(view, chat) do
    Chats.set(chat, started_at: DateTime.utc_now(:second))
    send(view.pid, :chats_changed)
    render(view)
  end

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

  defp tk(dir, args) do
    tk = Application.app_dir(:burrow, "priv/tk/tk")
    {out, 0} = System.cmd("bash", [tk | args], cd: Path.dirname(dir), env: [{"TICKETS_DIR", dir}])
    String.trim(out)
  end
end
