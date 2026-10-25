defmodule BurrowWeb.ChatsLiveTest do
  use BurrowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Burrow.ProjectHelpers

  alias Burrow.Accounts.Scope
  alias Burrow.{Chats, GeneralChats, Projects}

  @moduletag :tmp_dir
  # The model list has no opencode to talk to in tests.
  @moduletag :capture_log

  setup :register_and_log_in_user

  setup %{user: user, tmp_dir: dir} do
    {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "Watchtower"})
    %{project: start_project!(project, dir)}
  end

  # A chat with an answer that cites two pages, as its agent leaves it.
  defp answered_chat(user) do
    chat = GeneralChats.create_empty(user.id)
    GeneralChats.started(chat, "Web push in LiveView")

    GeneralChats.save_messages(chat, [
      %{id: "u1", role: :user, text: "Web push in LiveView", images: []},
      %{id: "t1", role: :tool, text: "websearch ", status: "completed"},
      %{
        id: "a1",
        role: :assistant,
        text: """
        Register a `service worker`.[1] Keep the key secret.[2]

        Sources:
        [1] Push API | https://developer.mozilla.org/push | "The Push API gives web apps"
        [2] https://web.dev/push
        """
      }
    ])

    GeneralChats.save_pages(chat, "u1", [
      %{url: "https://web.dev/push", title: "Push notifications", site: "web.dev", read?: true}
    ])

    GeneralChats.answered(chat, 2)
    GeneralChats.get(chat.id)
  end

  test "opens on an empty chat, with Chats in the switcher", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/chats") |> follow_redirect(conn)
    assert has_element?(view, ".ws-hello", "What do you want to know?")
    assert has_element?(view, "#space-switch", "Chats")
    assert has_element?(view, "#drawer .dswitch a[data-kb-key='0'][aria-current=page]", "Chats")
    assert has_element?(view, "#drawer .dswitch a.swt", "Watchtower")
    assert has_element?(view, "#web-toggle[aria-pressed=true]")
    refute has_element?(view, "#send-to-project")
    assert [%{started_at: nil}] = GeneralChats.list(user.id)

    # Opening Chats again reuses the empty chat.
    {:ok, _view, _html} = live(conn, ~p"/chats") |> follow_redirect(conn)
    assert length(GeneralChats.list(user.id)) == 1
  end

  test "shows an answer with its citations and sources", %{conn: conn, user: user} do
    chat = answered_chat(user)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "#gchat-#{chat.id}", "2 sources")
    assert has_element?(view, ".gc-searched", "Searched the web · 2 sources")
    assert has_element?(view, ".md code", "service worker")
    refute render(view) =~ "Sources:"
    assert has_element?(view, ".gc-card", "Push API")
    # A source named by its link alone takes the title the search found.
    assert has_element?(view, ".gc-card", "Push notifications")

    view |> element(".cite[phx-value-n='2']") |> render_click()
    assert has_element?(view, "#source-u1-2[data-on=true]")
    assert has_element?(view, ".cite[phx-value-n='2'][aria-pressed=true]")
  end

  test "searches chats here and in projects", %{conn: conn, user: user, project: project} do
    chat = answered_chat(user)
    there = Chats.create(project.id, "Push alerts for checks", user.email)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> form("#chat-search", q: "push") |> render_change()
    assert has_element?(view, ".dscroll .crb", "Web push in LiveView")
    refute has_element?(view, ".dscroll .crb", "Push alerts for checks")

    view |> element(".gc-scope button[phx-value-scope=everywhere]") |> render_click()
    assert has_element?(view, ".dscroll a[href='/projects/#{project.id}/c/#{there.id}']")
  end

  test "sends the chat to a project, where a new chat starts from it",
       %{conn: conn, user: user, project: project} do
    chat = answered_chat(user)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#send-to-project") |> render_click()
    assert has_element?(view, "#send-dialog .gc-ctx", "↳ from Chats: Web push in LiveView")
    view |> element(".gc-prj[phx-value-id='#{project.id}']") |> render_click()
    view |> form("#send-dialog") |> render_submit()

    assert [new] = Enum.filter(Chats.list(project.id), &(&1.from_chat == chat.id))
    assert has_element?(view, "#notice", "New chat in Watchtower, starting from this one.")
    assert has_element?(view, "#notice a[href='/projects/#{project.id}/c/#{new.id}']")
    # The chat stays in Chats.
    assert GeneralChats.get(chat.id)

    {:ok, workspace, _html} = live(conn, ~p"/projects/#{project.id}/c/#{new.id}")
    assert has_element?(workspace, "#from-chip", "↳ from Chats: Web push in LiveView")
    assert has_element?(workspace, "#drawer .dswitch a[data-kb-key='0']", "Chats")

    # Its agent reads the conversation.
    instructions =
      Burrow.Agent.Prompt.instructions(project, nil, %{
        title: chat.title,
        transcript: GeneralChats.transcript(chat)
      })

    assert instructions =~ "This chat starts from a conversation in Chats"
    assert instructions =~ "User: Web push in LiveView"

    workspace |> element("#from-chip button") |> render_click()
    refute has_element?(workspace, "#from-chip")
    assert Chats.get(new.id).from_chat == nil
  end

  test "starts a project from the chat", %{conn: conn, user: user} do
    chat = answered_chat(user)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> element("#start-project") |> render_click()
    assert has_element?(view, "#project-name[value='Web push in LiveView']")

    view |> form("#start-dialog", name: "1") |> render_submit()
    assert has_element?(view, "#start-dialog .say-error")

    view |> form("#start-dialog", name: "Push alerts") |> render_submit()
    project = Enum.find(Projects.list(Scope.for_user(user)), &(&1.name == "Push alerts"))
    assert [%{from_chat: from}] = Chats.list(project.id)
    assert from == chat.id

    assert has_element?(
             view,
             "#notice",
             "Created Push alerts with a chat that starts from this one."
           )
  end
end
