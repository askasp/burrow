defmodule Burrow.GeneralChatsTest do
  use Burrow.DataCase, async: false

  import Burrow.AccountsFixtures

  alias Burrow.GeneralChats
  alias Burrow.GeneralChats.Sources

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:burrow, :data_dir, dir)
    %{user: user_fixture()}
  end

  describe "chats" do
    test "an empty chat takes its title from its first message", %{user: user} do
      chat = GeneralChats.create_empty(user.id)
      assert %{title: "", started_at: nil} = GeneralChats.get(user.id, chat.id)

      GeneralChats.started(chat, "  How do I add\n web push?  ")

      assert %{title: "How do I add web push?", started_at: %DateTime{}} =
               GeneralChats.get(chat.id)

      GeneralChats.started(GeneralChats.get(chat.id), "Something else")
      assert GeneralChats.get(chat.id).title == "How do I add web push?"
    end

    test "are the user's own", %{user: user} do
      chat = GeneralChats.create_empty(user.id)
      other = user_fixture()
      refute GeneralChats.get(other.id, chat.id)
      assert GeneralChats.list(other.id) == []
    end

    test "list the latest answered first, and search by title", %{user: user} do
      older = GeneralChats.create_empty(user.id)
      GeneralChats.started(older, "Public holidays in Norway")
      newer = GeneralChats.create_empty(user.id)
      GeneralChats.started(newer, "Explain Oban unique jobs")
      GeneralChats.set(older, updated_at: ~U[2026-01-01 00:00:00Z])

      assert [%{id: id1}, %{id: id2}] = GeneralChats.list(user.id)
      assert {id1, id2} == {newer.id, older.id}

      assert [%{id: id}] = GeneralChats.search(user.id, "oban")
      assert id == newer.id
      assert GeneralChats.search(user.id, "%") == []
    end

    test "keep a copy of the conversation and its pages", %{user: user} do
      chat = GeneralChats.create_empty(user.id)
      assert GeneralChats.messages(chat) == []

      messages = [
        %{id: "u1", role: :user, text: "Is Elixir 1.20 out?", images: []},
        %{
          id: "a1",
          role: :assistant,
          text: "Yes.[1]\n\nSources:\n[1] https://elixir-lang.org/blog"
        }
      ]

      GeneralChats.save_messages(chat, messages)
      assert GeneralChats.messages(chat) == messages

      page = %{
        url: "https://elixir-lang.org/blog",
        title: "Blog",
        site: "elixir-lang.org",
        read?: true
      }

      GeneralChats.save_pages(chat, "u1", [page])
      assert GeneralChats.pages(chat) == %{"u1" => [page]}

      assert GeneralChats.transcript(chat) =~ "User: Is Elixir 1.20 out?\n\nPeon: Yes.[1]"
      assert String.length(GeneralChats.transcript(chat, 10)) == 10
    end
  end

  describe "sources" do
    test "come off the end of an answer" do
      text = """
      Use a service worker.[1] Keep the key secret.[2]

      Sources:
      [1] Push API | https://developer.mozilla.org/en-US/docs/Web/API/Push_API | "The Push API gives web apps"
      [2] https://web.dev/push
      """

      assert {"Use a service worker.[1] Keep the key secret.[2]", [one, two]} =
               Sources.split(text)

      assert one == %{
               n: 1,
               title: "Push API",
               url: "https://developer.mozilla.org/en-US/docs/Web/API/Push_API",
               site: "developer.mozilla.org",
               quote: "The Push API gives web apps"
             }

      assert %{n: 2, title: "web.dev", site: "web.dev", quote: nil} = two
    end

    test "an answer without a block has none" do
      assert Sources.split("Just this.") == {"Just this.", []}
      assert Sources.split("About Sources:\nnot a list") == {"About Sources:\nnot a list", []}
    end

    test "pages are what the web tools found, each once, read ones marked" do
      search = """
      ## [Push API - MDN](https://developer.mozilla.org/push)
      Published: 2026-01-01

      The Push API…

      ## [web.dev push](https://www.web.dev/push)
      """

      pages =
        Sources.pages([
          %{tool: "websearch", input: %{"query" => "push"}, output: search},
          %{
            tool: "webfetch",
            input: %{"url" => "https://developer.mozilla.org/push"},
            output: "…"
          }
        ])

      assert pages == [
               %{
                 url: "https://developer.mozilla.org/push",
                 title: "Push API - MDN",
                 read?: true,
                 site: "developer.mozilla.org"
               },
               %{
                 url: "https://www.web.dev/push",
                 title: "web.dev push",
                 read?: false,
                 site: "web.dev"
               }
             ]

      assert [%{n: 1, title: "Push API - MDN"}] = Sources.fallback(pages)
    end
  end
end
