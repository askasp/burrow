defmodule BurrowWeb.ProjectLiveTest do
  use BurrowWeb.ConnCase

  # The AI login check has no opencode to talk to in tests.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures

  import Ecto.Query

  alias Burrow.Accounts.Scope
  alias Burrow.{Inline, Projects, Teams}

  setup :register_and_log_in_user

  setup do
    # The cache outlives a test, and project ids repeat.
    Inline.forget_all()
    # No Peon runs; one that is asked answers as a stopped one would.
    Req.Test.stub(Inline, &Plug.Conn.send_resp(&1, 503, ""))
    :ok
  end

  test "creates a project and shows the slug it gets", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/projects")

    assert lv |> form("#project_form", project: %{name: "Sauna Booking"}) |> render_change() =~
             "slug: sauna_booking"

    lv |> form("#project_form", project: %{name: "Sauna Booking"}) |> render_submit()
    assert has_element?(lv, "#selected-project h2", "Sauna Booking")
    # New projects are live-only: the app shows inline, nothing built yet.
    assert has_element?(lv, "#inline", "Nothing here yet")
    assert has_element?(lv, "#inline-msg[placeholder='What should Sauna Booking do?']")
    assert has_element?(lv, "#view-dev[disabled]")
  end

  test "the owner shares a project with a team; teammates see it", %{conn: conn, user: user} do
    scope = Scope.for_user(user)
    {:ok, team} = Teams.create(scope, %{"name" => "Ops"})
    mate = user_fixture()
    {:ok, _} = Teams.add_member(scope, team, mate.email)
    {:ok, project} = Projects.create(scope, %{"name" => "Procedures"})

    {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
    refute has_element?(lv, "#share-form")
    assert has_element?(lv, "#project-menu-button[aria-expanded='false']")
    lv |> element("#project-menu-button") |> render_click()
    assert has_element?(lv, "#project-menu-button[aria-expanded='true']")
    lv |> element("#project-menu button", "Share") |> render_click()
    lv |> form("#share-form", share: %{team_id: team.id}) |> render_change()
    assert has_element?(lv, "#project-#{project.id}", "shared")
    assert Projects.get!(scope, project.id).team_id == team.id

    {:ok, mate_lv, _html} = live(log_in_user(build_conn(), mate), ~p"/projects")
    assert has_element?(mate_lv, "#project-#{project.id}", user.email)
    refute has_element?(mate_lv, "#project-menu-button")
  end

  test "a project with staging and prod keeps its overview", %{conn: conn, user: user} do
    {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "Procedures"})
    pipeline!(project)

    {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
    assert has_element?(lv, "#restart-peon")
    assert has_element?(lv, "#selected-project", "Only you can see it.")
    assert has_element?(lv, "#project-meta", "Peon on port #{project.port}")
    refute has_element?(lv, "#inline")

    lv |> element("#project-menu-button") |> render_click()
    refute has_element?(lv, "#add-envs")
  end

  describe "a live-only project" do
    setup %{user: user} do
      {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "Watchtower"})
      Inline.put(project.id, state(nil, nil, live: 8))
      %{project: project}
    end

    test "the loop: ask, checks, dev preview, merge, live", %{conn: conn, project: project} do
      {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
      running!(project)
      assert has_element?(lv, "#project-meta", "watchtower · live #8 · private")
      assert has_element?(lv, "#project-#{project.id} .lbl.live", "live")
      assert has_element?(lv, "#project-#{project.id}", "dev —")
      assert has_element?(lv, "iframe[src='http://localhost:5099']")
      assert has_element?(lv, "#inline-msg[placeholder='Ask Peon to change Watchtower']")
      assert has_element?(lv, "#inline-send[disabled]")

      Req.Test.stub(Inline, fn conn ->
        assert conn.request_path == "/api/inline/send"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["text"] == "Put anything that's down at the top"
        assert params["effort"] == "high"
        assert params["user"] =~ "@"
        Req.Test.json(conn, state("writing", nil, live: 8, busy: true, sent: params["text"]))
      end)

      lv |> element("button[aria-label='Effort high']") |> render_click()

      lv
      |> form("#inline-composer", text: "Put anything that's down at the top")
      |> render_change()

      refute has_element?(lv, "#inline-send[disabled]")

      lv
      |> form("#inline-composer", text: "Put anything that's down at the top")
      |> render_submit()

      assert has_element?(lv, "#thread .bubble-user", "Put anything that's down at the top")
      assert has_element?(lv, "#thread .wk", "Peon is working…")
      assert has_element?(lv, "#project-#{project.id} .lbl.working", "working")
      assert has_element?(lv, "#merge[disabled]")
      # The preview stays on live while Peon works.
      assert has_element?(lv, "iframe[src='http://localhost:5099']")

      Inline.put(project.id, state("checking", 9, live: 8, busy: true, running: "compile"))
      assert has_element?(lv, "#project-meta", "#9 · compile")
      assert has_element?(lv, "#changeset", "Changeset #9")
      assert has_element?(lv, "#changeset .step.run", "compile")
      assert has_element?(lv, "#project-#{project.id}", "dev #9")

      # Checks pass: the viewer moves to the dev build by itself.
      Inline.put(project.id, state("ready", 9, live: 8))
      assert has_element?(lv, "#project-#{project.id} .lbl.waiting", "waiting on you")
      assert has_element?(lv, "#view-dev[aria-pressed='true']", "dev #9")
      assert has_element?(lv, "iframe[src='http://localhost:5091']")
      assert has_element?(lv, "#changeset", "checks passed")
      refute has_element?(lv, "#merge[disabled]")

      Req.Test.stub(Inline, fn conn ->
        assert conn.request_path == "/api/inline/merge"
        Req.Test.json(conn, state("landing", 9, live: 9, good: 8, deploy: "watching"))
      end)

      lv |> element("#merge") |> render_click()
      assert has_element?(lv, "#changeset .dep", "Going live")
      assert has_element?(lv, "#thread .evt", "#9 merging to main…")

      Inline.put(project.id, state("live", 9, live: 9))
      assert has_element?(lv, "#changeset .live", "Live")
      assert has_element?(lv, "#thread .evt.ok", "#9 on main · live")
      assert has_element?(lv, "#view-dev[aria-pressed='false']")
      assert has_element?(lv, "#changeset .flow", "dev #9")
      assert has_element?(lv, "#project-meta", "live #9")
      assert has_element?(lv, "#project-#{project.id} .lbl.live", "live")
      assert has_element?(lv, "#open-workspace[href='/projects/#{project.id}/open?chat=c1']")
    end

    test "discard drops the changeset and the dev view", %{conn: conn, project: project} do
      Inline.put(project.id, state("ready", 9, live: 8))
      {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
      running!(project)

      Req.Test.stub(Inline, fn conn ->
        assert conn.request_path == "/api/inline/discard"
        Req.Test.json(conn, state(nil, nil, live: 8))
      end)

      lv |> element("#discard") |> render_click()
      refute has_element?(lv, "#changeset")
      assert has_element?(lv, "#view-dev[disabled]", "dev")
      assert has_element?(lv, "iframe[src='http://localhost:5099']")
    end

    test "add staging and prod turns it into a pipeline project", %{conn: conn, project: project} do
      {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
      running!(project)

      Req.Test.stub(Inline, fn conn ->
        assert conn.request_path == "/api/inline/add-envs"
        Req.Test.json(conn, %{state(nil, nil, live: 8) | "mode" => "pipeline"})
      end)

      lv |> element("#project-menu-button") |> render_click()
      lv |> element("#add-envs") |> render_click()
      assert render(lv) =~ "Watchtower has staging and prod now. Both run #8."
      assert has_element?(lv, "#restart-peon")
      refute has_element?(lv, "#inline")
      assert Projects.get(project.id).envs == "pipeline"
    end

    test "Peon pushes its state with the shared token", %{conn: conn, project: project} do
      Inline.subscribe()
      pushed = state("checking", 9, live: 8)

      conn
      |> put_req_header("authorization", "Bearer " <> Inline.token(project))
      |> post(~p"/api/peon/#{project.id}/inline", pushed)
      |> response(204)

      assert_receive {:inline, id, %{"changeset" => %{"id" => 9}}}
      assert id == project.id

      assert build_conn()
             |> put_req_header("authorization", "Bearer nope")
             |> post(~p"/api/peon/#{project.id}/inline", pushed)
             |> json_response(401)

      # A push that arrives late doesn't undo a newer one.
      Inline.put(project.id, %{pushed | "seq" => 1})
      assert Inline.get(project.id)["changeset"]["id"] == 9
    end
  end

  # Tests run no Peons; tell the page this one runs, as its cell would.
  defp running!(project),
    do: Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, project.id, :running})

  defp pipeline!(project) do
    Burrow.Repo.update_all(
      from(p in Burrow.Projects.Project, where: p.id == ^project.id),
      set: [envs: "pipeline"]
    )
  end

  # A state as Peon pushes it (see Peon.Inline).
  defp state(phase, id, opts) do
    steps =
      for name <- ~w(deps compile format test) do
        status =
          cond do
            phase in [nil, "writing"] -> "waiting"
            phase == "checking" and name == opts[:running] -> "running"
            phase == "checking" and name in ~w(format test) -> "waiting"
            true -> "passed"
          end

        %{"name" => name, "status" => status}
      end

    chat =
      if phase do
        %{
          "id" => "c1",
          "title" => "Down first",
          "busy" => opts[:busy] == true,
          "model" => nil,
          "effort" => "high",
          "messages" => [
            %{"role" => "user", "text" => opts[:sent] || "Put anything that's down at the top"},
            %{"role" => "tool", "text" => "edit lib/watchtower_web/live/status_live.ex"}
          ],
          "error" => nil,
          "preview_url" => "http://localhost:5091",
          "preview_status" => "running"
        }
      end

    %{
      "seq" => System.os_time(:microsecond),
      "mode" => "live",
      "main" => opts[:live],
      "live" => %{
        "tip" => opts[:live],
        "good" => Keyword.get(opts, :good, opts[:live]),
        "url" => "http://localhost:5099",
        "status" => if(opts[:deploy], do: "building", else: "running")
      },
      "chat" => chat,
      "changeset" =>
        phase &&
          %{
            "id" => id,
            "intent" => "Down checks first",
            "status" => "passed",
            "phase" => phase,
            "steps" => steps,
            "deploy" => opts[:deploy]
          }
    }
  end
end
