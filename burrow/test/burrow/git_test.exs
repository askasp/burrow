defmodule Burrow.GitRepoTest do
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{GitRepo, Secrets}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    origin = Path.join(dir, "origin.git")
    work = Path.join(dir, "work")
    sh!(["init", "--bare", "-b", "main", origin], dir)
    sh!(["init", "-b", "main", work], dir)
    File.write!(Path.join(work, "index.html"), "v1")
    commit!(work, "first")
    sh!(["remote", "add", "origin", origin], work)
    sh!(["push", "origin", "main"], work)

    %{origin: origin, work: work, project: project_fixture(%{repo_url: origin})}
  end

  test "each chat gets its own branch from main, fetched fresh", %{
    tmp_dir: dir,
    origin: origin,
    work: work,
    project: project
  } do
    a = Path.join(dir, "chats/a/workspace")
    refute GitRepo.checked_out?(a)
    assert :ok = GitRepo.checkout(project, a, "a")
    assert File.read!(Path.join(a, "index.html")) == "v1"
    assert git!(["branch", "--show-current"], a) == "peon/a"
    assert git!(["remote", "get-url", "origin"], a) == origin

    File.write!(Path.join(work, "index.html"), "v2")
    commit!(work, "second")
    sh!(["push", "origin", "main"], work)

    b = Path.join(dir, "chats/b/workspace")
    assert :ok = GitRepo.checkout(project, b, "b")
    assert File.read!(Path.join(b, "index.html")) == "v2"
    assert File.read!(Path.join(a, "index.html")) == "v1"
  end

  test "a repo it can't read asks for a GitHub token, which never reaches the app", %{
    tmp_dir: dir
  } do
    project = project_fixture(%{repo_url: Path.join(dir, "missing.git")})

    assert {:error, "git clone" <> _} = GitRepo.checkout(project, Path.join(dir, "ws"), "c")
    assert [%{name: "GITHUB_TOKEN", set?: false}] = Secrets.list(project.id)

    :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")
    assert GitRepo.token(project) == "github_pat_x"
    assert Secrets.env(project.id) == %{}
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
