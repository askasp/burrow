defmodule Burrow.GitRepo.PullRequestTest do
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{GitRepo, Secrets}
  alias Burrow.Agent.Tools
  alias Burrow.GitRepo.{Merged, PullRequest}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    work = Path.join(dir, "work")
    sh!(["init", "--bare", "-b", "main", origin], dir)
    sh!(["init", "-b", "main", work], dir)
    File.write!(Path.join(work, "index.html"), "one\ntwo\n")
    commit!(work, "first")
    sh!(["remote", "add", "origin", origin], work)
    sh!(["push", "origin", "main"], work)

    project = project_fixture(%{repo_url: origin})
    previous = Application.get_env(:burrow, :github_req)
    Application.put_env(:burrow, :github_req, plug: {Req.Test, PullRequest})
    on_exit(fn -> Application.put_env(:burrow, :github_req, previous) end)

    chat = Path.join(dir, "chats/a/workspace")
    :ok = GitRepo.checkout(project, chat, "a")
    %{origin: origin, work: work, chat: chat, project: project}
  end

  test "a submit commits, merges main and pushes the chat's branch", %{
    origin: origin,
    work: work,
    chat: chat,
    project: project
  } do
    assert {:error, :no_changes} = PullRequest.submit(project, "a", chat, "Nothing", "")

    File.write!(Path.join(chat, "index.html"), "one\ntwo\nthree\n")
    File.write!(Path.join(chat, "new.txt"), "hi")
    File.write!(Path.join(work, "other.txt"), "from main")
    commit!(work, "meanwhile")
    sh!(["push", "origin", "main"], work)

    assert {:ok, nil} = PullRequest.submit(project, "a", chat, "Add a third line", "")

    assert git!(["show", "peon/a:index.html"], origin) == "one\ntwo\nthree"
    assert git!(["show", "peon/a:other.txt"], origin) == "from main"
    assert git!(["log", "-2", "--format=%an %s", "peon/a"], origin) =~ "Peon Add a third line"

    assert {:error, :no_changes} = PullRequest.submit(project, "a", chat, "Again", "")
  end

  test "a conflict with main is left for the agent to resolve", %{
    origin: origin,
    work: work,
    chat: chat,
    project: project
  } do
    File.write!(Path.join(work, "index.html"), "one\nTWO\n")
    commit!(work, "main's two")
    sh!(["push", "origin", "main"], work)
    File.write!(Path.join(chat, "index.html"), "one\nzwei\n")

    assert {:error, {:conflict, ["index.html"]}} =
             PullRequest.submit(project, "a", chat, "Zwei", "")

    assert File.read!(Path.join(chat, "index.html")) =~ "<<<<<<<"

    assert {:error, {:unresolved, ["index.html"]}} =
             PullRequest.submit(project, "a", chat, "Zwei", "")

    File.write!(Path.join(chat, "index.html"), "one\nTWO zwei\n")
    assert {:ok, nil} = PullRequest.submit(project, "a", chat, "Zwei", "")
    assert git!(["show", "peon/a:index.html"], origin) == "one\nTWO zwei"
  end

  test "a failing check pushes nothing", %{origin: origin, chat: chat, project: project} do
    File.write!(Path.join(chat, "index.html"), "broken")

    assert {:error, {:check_failed, "nope " <> _}} =
             PullRequest.submit(
               project,
               "a",
               chat,
               "Break it",
               "",
               {"echo nope $WHO; exit 1", %{"WHO" => "x"}}
             )

    assert {_, 128} =
             System.cmd("git", ["rev-parse", "peon/a"], cd: origin, stderr_to_stdout: true)
  end

  # Setting the token tells chat "a", which isn't running here.
  @tag :capture_log
  test "on GitHub it needs the token, then opens the PR once and finds it after", %{
    origin: origin,
    chat: chat
  } do
    project = project_fixture(%{repo_url: "https://github.com/acme/shop.git"})
    # The push still goes to the local origin; only the API is GitHub's.
    sh!(["remote", "set-url", "origin", origin], chat)
    File.write!(Path.join(chat, "index.html"), "new")

    assert {:error, :no_token} = PullRequest.submit(project, "a", chat, "New", "Body")
    assert [%{name: "GITHUB_TOKEN", chat_id: "a"}] = Secrets.list(project.id)
    :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")

    test = self()

    Req.Test.stub(PullRequest, fn conn ->
      send(
        test,
        {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
      )

      case {conn.method, conn.request_path} do
        {"GET", "/user"} ->
          Req.Test.json(conn, %{"login" => "ada", "id" => 7, "name" => "Ada"})

        {"GET", "/repos/acme/shop/pulls"} ->
          prs = if conn.query_string =~ "head=acme%3Apeon%2Fa", do: [], else: [:wrong_query]
          Req.Test.json(conn, prs)

        {"POST", "/repos/acme/shop/pulls"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:pr, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"html_url" => "https://github.com/acme/shop/pull/12"})
      end
    end)

    assert {:ok, "https://github.com/acme/shop/pull/12"} =
             PullRequest.submit(project, "a", chat, "New", "Body")

    assert_received {"GET", "/user", ["Bearer github_pat_x"]}

    assert_received {:pr,
                     %{"title" => "New", "body" => "Body", "head" => "peon/a", "base" => "main"}}

    assert git!(["log", "-1", "--format=%an <%ae>", "peon/a"], origin) ==
             "Ada <7+ada@users.noreply.github.com>"

    Req.Test.stub(PullRequest, fn conn ->
      case conn.request_path do
        "/user" -> Req.Test.json(conn, %{"login" => "ada", "id" => 7})
        _ -> Req.Test.json(conn, [%{"html_url" => "https://github.com/acme/shop/pull/12"}])
      end
    end)

    File.write!(Path.join(chat, "index.html"), "newer")

    assert {:ok, "https://github.com/acme/shop/pull/12"} =
             PullRequest.submit(project, "a", chat, "Newer", "Body")
  end

  test "reads another PR and fetches its branch into the checkout", %{
    origin: origin,
    work: work,
    chat: chat
  } do
    project = project_fixture(%{repo_url: "https://github.com/acme/shop.git"})
    sh!(["remote", "set-url", "origin", origin], chat)
    :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")

    sh!(["checkout", "-q", "-b", "push"], work)
    File.write!(Path.join(work, "push.ex"), "no secrets")
    commit!(work, "push")
    sh!(["push", "-q", "origin", "push:refs/pull/3/head"], work)

    pr = %{
      "number" => 3,
      "title" => "Push",
      "state" => "open",
      "base" => %{"ref" => "main"},
      "head" => %{"ref" => "push"}
    }

    Req.Test.stub(PullRequest, fn conn ->
      case conn.request_path do
        "/repos/acme/shop/pulls/3" -> Req.Test.json(conn, pr)
        "/repos/acme/shop/pulls" -> Req.Test.json(conn, [pr])
      end
    end)

    assert {:ok, %{"title" => "Push"}} = PullRequest.read(project, "a", chat, 3)
    assert git!(["show", "origin/pr/3:push.ex"], chat) == "no secrets"
    assert git!(["diff", "--name-only", "origin/main...origin/pr/3"], chat) == "push.ex"
    assert {:ok, [%{"number" => 3}]} = PullRequest.open_list(project, "a")

    assert {:error, :not_github} =
             PullRequest.read(project_fixture(%{repo_url: origin}), "a", chat, 3)
  end

  test "the agent reads a PR's comments and reviews, Copilot's too, and answers them", %{
    work: work,
    project: local
  } do
    project = project_fixture(%{repo_url: "https://github.com/acme/shop.git"})
    :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")
    chat = Burrow.Chat.workspace_dir(project, "c")
    on_exit(fn -> File.rm_rf!(Burrow.Projects.dir(project)) end)
    # cloned from the local origin; only the API is GitHub's
    :ok = GitRepo.checkout(local, chat, "c")

    sh!(["checkout", "-q", "-b", "fix"], work)
    File.write!(Path.join(work, "a.ex"), "fixed")
    commit!(work, "fix")
    sh!(["push", "-q", "origin", "fix:refs/pull/4/head", "fix:peon/c"], work)

    pr = %{
      "number" => 4,
      "title" => "Fix",
      "state" => "open",
      "user" => %{"login" => "ada"},
      "base" => %{"ref" => "main"},
      "head" => %{"ref" => "peon/c"},
      "html_url" => "https://github.com/acme/shop/pull/4"
    }

    copilot = %{"login" => "copilot-pull-request-reviewer[bot]"}

    Req.Test.stub(PullRequest, fn conn ->
      case conn.request_path do
        "/repos/acme/shop/pulls" ->
          Req.Test.json(conn, [pr])

        "/repos/acme/shop/pulls/4" ->
          Req.Test.json(conn, pr)

        "/repos/acme/shop/issues/4/comments" ->
          Req.Test.json(conn, [
            %{
              "user" => %{"login" => "ada"},
              "body" => "Thanks!",
              "created_at" => "2026-10-22T09:00:00Z"
            }
          ])

        "/repos/acme/shop/pulls/4/reviews" ->
          Req.Test.json(conn, [
            %{
              "user" => copilot,
              "state" => "COMMENTED",
              "body" => "Copilot reviewed 1 file.",
              "submitted_at" => "2026-10-20T09:00:00Z"
            },
            %{
              "user" => %{"login" => "bo"},
              "state" => "COMMENTED",
              "body" => "",
              "submitted_at" => "x"
            },
            %{"user" => %{"login" => "bo"}, "state" => "PENDING", "body" => "draft"},
            %{
              "user" => %{"login" => "bo"},
              "state" => "CHANGES_REQUESTED",
              "body" => nil,
              "submitted_at" => "2026-10-23T09:00:00Z"
            }
          ])

        "/repos/acme/shop/pulls/4/comments" ->
          Req.Test.json(conn, [
            %{
              "id" => 11,
              "user" => %{"login" => "Copilot"},
              "body" => "This can be nil.",
              "path" => "a.ex",
              "line" => 3,
              "original_line" => 3,
              "created_at" => "2026-10-20T09:00:01Z"
            },
            %{
              "id" => 13,
              "in_reply_to_id" => 11,
              "user" => %{"login" => "ada"},
              "body" => "Good catch.",
              "path" => "a.ex",
              "line" => 3,
              "original_line" => 3,
              "created_at" => "2026-10-20T10:00:00Z"
            },
            %{
              "id" => 12,
              "user" => nil,
              "body" => "Typo.",
              "path" => "b.ex",
              "line" => nil,
              "original_line" => 9,
              "created_at" => "2026-10-21T09:00:00Z"
            }
          ])
      end
    end)

    assert {:ok,
            [%{author: "copilot-pull-request-reviewer[bot]", review: "commented"} | _] = said} =
             PullRequest.comments(project, "c", 4)

    assert Enum.map(said, & &1.author) ==
             ~w(copilot-pull-request-reviewer[bot] Copilot ada ghost ada bo)

    assert {text, false} = Tools.call("pull_request", %{"number" => 4}, project, "c")

    assert text =~ """
           Comments and reviews, oldest first:

           copilot-pull-request-reviewer[bot] reviewed (commented), 2026-10-20:
           Copilot reviewed 1 file.

           Copilot on a.ex:3 (thread 11), 2026-10-20:
           This can be nil.

           ada on a.ex:3 (thread 11), 2026-10-20:
           Good catch.

           ghost on b.ex:9 (outdated, thread 12), 2026-10-21:
           Typo.

           ada, 2026-10-22:
           Thanks!

           bo reviewed (changes requested), 2026-10-23:\
           """

    assert git!(["show", "origin/pr/4:a.ex"], chat) == "fixed"

    assert {"#4 Fix (open, by ada, peon/c), yours", false} =
             Tools.call("pull_request", %{}, project, "c")

    test = self()

    Req.Test.stub(PullRequest, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {conn.method, conn.request_path, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"html_url" => "https://github.com/acme/shop/pull/4#r14"})
    end)

    reply = %{"number" => 4, "reply_to" => 11, "body" => " Fixed: it can't be nil now. "}

    assert {"Posted: https://github.com/acme/shop/pull/4#r14", false} =
             Tools.call("comment_on_pull_request", reply, project, "c")

    assert_received {"POST", "/repos/acme/shop/pulls/4/comments/11/replies",
                     %{"body" => "Fixed: it can't be nil now.\n\n_From Peon._"}}

    assert {_, false} =
             Tools.call(
               "comment_on_pull_request",
               %{"number" => "4", "body" => "Done."},
               project,
               "c"
             )

    assert_received {"POST", "/repos/acme/shop/issues/4/comments",
                     %{"body" => "Done.\n\n_From Peon._"}}

    assert {"Write what to say in body.", true} =
             Tools.call("comment_on_pull_request", %{"number" => 4, "body" => " "}, project, "c")
  end

  test "refresh notes which chats' PRs were merged or closed" do
    project = project_fixture(%{repo_url: "https://github.com/acme/shop.git"})
    :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")

    for n <- 1..4 do
      chat = Burrow.Chats.create(project.id, "PR #{n}", "ada")
      Burrow.Chats.set(chat, pr_url: "https://github.com/acme/shop/pull/#{n}", pr_state: "open")
    end

    Req.Test.stub(PullRequest, fn conn ->
      case conn.request_path do
        "/repos/acme/shop/pulls/1" ->
          Req.Test.json(conn, %{"state" => "closed", "merged_at" => "x"})

        "/repos/acme/shop/pulls/2" ->
          Req.Test.json(conn, %{"state" => "closed", "merged_at" => nil})

        _ ->
          Req.Test.json(conn, %{"state" => "open", "merged_at" => nil})
      end
    end)

    assert PullRequest.refresh(project) == 2
    states = Burrow.Chats.list(project.id) |> Enum.map(& &1.pr_state) |> Enum.sort()
    assert states == ~w(closed merged open open)

    phases = Burrow.Activity.chats(project, MapSet.new()) |> Enum.map(& &1.phase) |> Enum.sort()
    assert phases == ~w(closed merged ready ready)
    assert PullRequest.refresh(project) == 0
  end

  test "a chat closes once its PR is merged, unless its checkout has more", %{tmp_dir: dir} do
    project = project_fixture(%{repo_url: "https://github.com/acme/shop.git"})
    :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")

    [none, pushed, edited, open] =
      for n <- 1..4 do
        chat = Burrow.Chats.create(project.id, "PR #{n}", "ada")
        Burrow.Chats.set(chat, pr_url: "https://github.com/acme/shop/pull/#{n}", pr_state: "open")
        chat
      end

    for chat <- [pushed, edited] do
      work = Burrow.Chat.workspace_dir(project, chat.id)
      sh!(["init", "-b", "peon/#{chat.id}", work], dir)
      File.write!(Path.join(work, "index.html"), "one\n")
      commit!(work, "first")
      sh!(["update-ref", "refs/remotes/origin/peon/#{chat.id}", "HEAD"], work)
    end

    File.write!(Path.join(Burrow.Chat.workspace_dir(project, edited.id), "new.html"), "two\n")

    Req.Test.stub(PullRequest, fn conn ->
      if conn.request_path == "/repos/acme/shop/pulls/4",
        do: Req.Test.json(conn, %{"state" => "open", "merged_at" => nil}),
        else: Req.Test.json(conn, %{"state" => "closed", "merged_at" => "x"})
    end)

    assert Enum.sort(Merged.close(project)) == Enum.sort([none.id, pushed.id])
    left = Burrow.Chats.list(project.id) |> Enum.map(& &1.id) |> Enum.sort()
    assert left == Enum.sort([edited.id, open.id])
  end

  defp commit!(dir, message) do
    sh!(["add", "-A"], dir)
    sh!(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", message], dir)
  end

  defp git!(args, dir), do: sh!(args, dir) |> String.trim()

  defp sh!(args, dir) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
