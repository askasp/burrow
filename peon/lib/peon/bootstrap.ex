defmodule Peon.Bootstrap do
  @moduledoc """
  On first boot, creates the project from the template as changeset 1.
  Runs once during startup, before checks and previews start.
  """

  require Logger

  alias Peon.{Code, Store, Template}

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
      {:ok, cs} = Store.import_tree(tree, blobs, slug, name, %{kind: :human, id: "burrow"})
      Logger.info("created #{slug} from the template as changeset #{cs.id}")
    end
  end
end
