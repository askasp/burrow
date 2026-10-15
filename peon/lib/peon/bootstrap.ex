defmodule Peon.Bootstrap do
  @moduledoc """
  On first boot, creates the project from the template as changeset 1.
  Runs once during startup, before checks and previews start.
  """

  require Logger

  alias Peon.{Code, Sandbox, Store, Template}

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  # Runs synchronously so later children see the imported project.
  def start_link do
    run()
    :ignore
  end

  def run do
    Peon.Sandbox.remove_all()

    if Code.ref("main") == nil and Application.get_env(:peon, :template_dir) do
      slug = Application.fetch_env!(:peon, :project_slug)
      name = Application.fetch_env!(:peon, :project_name)
      otp_app = Template.otp_app(slug)
      {tree, blobs} = Template.instantiate(Application.fetch_env!(:peon, :template_dir), otp_app)
      {tree, blobs} = formatted(tree, blobs)
      {:ok, cs} = Store.import_tree(tree, blobs, slug, name, %{kind: :human, id: "burrow"})
      Logger.info("created #{slug} from the template as changeset #{cs.id}")
    end
  end

  # Renaming the template's modules changes line lengths, so the new project
  # is run through `mix format` once; otherwise the first `mix format` in any
  # chat would rewrite files it never meant to touch. Unchanged on failure.
  defp formatted(tree, blobs) do
    dir = Path.join(Application.fetch_env!(:peon, :data_dir), "bootstrap")
    File.rm_rf!(dir)

    for {path, hash} <- tree do
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, Map.fetch!(blobs, hash))
    end

    case Sandbox.run(dir, "mix deps.get && mix format", env: %{"MIX_ENV" => "test"}) do
      {0, _output, _ms} ->
        PeonCore.Tree.from_dir(dir, PeonCore.Ignore.matcher(dir))

      {status, output, _ms} ->
        Logger.warning("could not format the new project (#{inspect(status)}): #{output}")
        {tree, blobs}
    end
  after
    File.rm_rf(Path.join(Application.fetch_env!(:peon, :data_dir), "bootstrap"))
  end
end
