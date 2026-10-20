defmodule Burrow.PeonHelpers do
  @moduledoc """
  A project's Peon for tests: a real `Peon.Instance` on its own database in
  `dir`, without the workers that touch Docker (`:start_workers` is off in
  tests). The test process works for it afterwards (`Peon.Instance.put/1`).
  """

  import ExUnit.Callbacks

  def start_peon!(project, dir, opts \\ []) do
    instance =
      Peon.Instance.new(
        id: project.id,
        slug: project.slug,
        name: project.name,
        data_dir: Path.join(dir, "peon-#{project.id}"),
        env_ports: Keyword.get(opts, :env_ports, %{}),
        envs: project.envs,
        secret: "test-secret-0123456789-0123456789"
      )

    start_supervised!({Peon.Instance, instance})
    Peon.Instance.put(instance)
  end

  @doc "Imports a small app as the project's first changeset."
  def import_app!(dir, name) do
    app = Path.join(dir, "app")
    File.mkdir_p!(Path.join(app, "lib"))
    File.write!(Path.join(app, "mix.exs"), "defmodule App.MixProject do end")
    File.write!(Path.join(app, "lib/app.ex"), "defmodule App do end")
    slug = Burrow.Projects.slug_base(name)
    {:ok, base} = Peon.Store.import_dir(app, slug, name, %{kind: :human, id: "aksel"})
    base
  end

  def assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> ExUnit.Assertions.flunk("never happened")
      true -> Process.sleep(20) && assert_eventually(fun, tries - 1)
    end
  end
end
