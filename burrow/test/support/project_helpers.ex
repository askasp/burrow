defmodule Burrow.ProjectHelpers do
  @moduledoc """
  A running project for tests: its cell marked as running (from the test
  process, so it goes with the test) and a small app as its history's first
  change, under `dir`. No containers.
  """

  alias Burrow.Projects

  def start_project!(project, dir) do
    Application.put_env(:burrow, :data_dir, dir)
    {:ok, _} = Registry.register(Burrow.CellRegistry, project.id, :running)

    files = %{"mix.exs" => "defmodule App.MixProject do end\n", "lib/app.ex" => "defmodule App do end\n"}
    tree = Map.new(files, fn {path, content} -> {path, Totem.Blob.hash(content)} end)
    blobs = Map.new(files, fn {_path, content} -> {Totem.Blob.hash(content), content} end)
    {:ok, _} = Totem.Repo.init(Projects.repo_dir(project), tree, blobs, "Create", "burrow")
    project
  end

  @doc "Lands a change from `chat` on main, as its checks passing would."
  def land!(project, chat, path, content) do
    repo = Projects.repo_dir(project)
    {:ok, _} = Totem.Repo.put_draft(repo, chat.id, Totem.Repo.ref(repo, "main"), [{path, content}], intent: "Change #{path}")
    Totem.Repo.update_draft(repo, chat.id, status: "passed", checks: %{"steps" => [%{"name" => "test", "status" => "passed"}]})
    {:ok, change} = Totem.Repo.land(repo, chat.id, chat.id)
    change
  end

  def assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> ExUnit.Assertions.flunk("never happened")
      true -> Process.sleep(20) && assert_eventually(fun, tries - 1)
    end
  end
end
