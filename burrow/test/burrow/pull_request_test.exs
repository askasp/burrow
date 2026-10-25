defmodule Burrow.GitRepo.PullRequestTest do
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{GitRepo, Secrets}
  alias Burrow.GitRepo.PullRequest

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
