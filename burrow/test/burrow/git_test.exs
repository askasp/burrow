defmodule Peon.GitTest do
  use Peon.DataCase, async: false

  alias Peon.{Git, Secrets}

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

    put_instance(repo: %{url: origin, branch: "main"}, data_dir: Path.join(dir, "data"))

    %{origin: origin, work: work}
  end

  test "each chat gets its own branch from main, fetched fresh", %{
    tmp_dir: dir,
    origin: origin,
    work: work
  } do
    a = Path.join(dir, "chats/a/workspace")
    refute Git.checked_out?(a)
    assert :ok = Git.checkout(a, "a")
    assert Git.checked_out?(a)
    assert File.read!(Path.join(a, "index.html")) == "v1"
    assert git!(["branch", "--show-current"], a) == "peon/a"
    assert git!(["remote", "get-url", "origin"], a) == origin

    File.write!(Path.join(work, "index.html"), "v2")
    commit!(work, "second")
    sh!(["push", "origin", "main"], work)

    b = Path.join(dir, "chats/b/workspace")
    assert :ok = Git.checkout(b, "b")
    assert File.read!(Path.join(b, "index.html")) == "v2"
    assert File.read!(Path.join(a, "index.html")) == "v1"
  end

  test "a repo it can't read asks for a GitHub token, which never reaches the app", %{
    tmp_dir: dir
  } do
    put_instance(repo: %{url: Path.join(dir, "missing.git"), branch: "main"})

    assert {:error, "git clone" <> _} = Git.checkout(Path.join(dir, "ws"), "c")
    assert [%{name: "GITHUB_TOKEN", set?: false}] = Secrets.requested()

    :ok = Secrets.put("GITHUB_TOKEN", "github_pat_x", "ada")
    assert Secrets.env_value("GITHUB_TOKEN") == "github_pat_x"
    assert Secrets.env() == %{}
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
