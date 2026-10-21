defmodule Burrow.ProjectFixtures do
  @moduledoc "Projects for backend tests: a row, and optionally its history (`Totem.Repo`)."

  alias Burrow.{Projects, Repo}
  alias Burrow.Projects.Project

  @doc "A project row; its files are removed when the test ends."
  def project_fixture(attrs \\ %{}) do
    user = Burrow.AccountsFixtures.user_fixture()
    slug = "p#{System.unique_integer([:positive])}"

    project =
      Repo.insert!(
        struct!(
          %Project{user_id: user.id, name: "Shop", slug: slug, preview_ports: "21000-21049"},
          Map.to_list(attrs)
        )
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(Projects.dir(project)) end)
    project
  end

  @doc "Gives `project` a history whose first change has `files` (path => content)."
  def history!(project, files) do
    tree = Map.new(files, fn {path, content} -> {path, Totem.Blob.hash(content)} end)
    blobs = Map.new(files, fn {_path, content} -> {Totem.Blob.hash(content), content} end)
    {:ok, change} = Totem.Repo.init(Projects.repo_dir(project), tree, blobs, "Import", "test")
    change
  end
end
