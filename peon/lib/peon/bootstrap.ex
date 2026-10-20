defmodule Peon.Bootstrap do
  @moduledoc """
  On first boot, creates the project from the template as changeset 1, with
  the login Burrow picked (`:auth`, see `Peon.Template`). Runs once during
  startup, before checks and previews start.

  For `"basic"`, Burrow passes the username and password once, in
  `PEON_BASIC_AUTH_USERNAME` and `PEON_BASIC_AUTH_PASSWORD`; they become the
  app's secrets `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD` and leave
  Peon's environment. Without them the owner is asked to set those secrets.
  """

  require Logger

  alias Peon.{Code, Project, Sandbox, Secrets, Store, Template}

  @basic_auth [
    {"BASIC_AUTH_USERNAME", "PEON_BASIC_AUTH_USERNAME", "The username the app asks for."},
    {"BASIC_AUTH_PASSWORD", "PEON_BASIC_AUTH_PASSWORD", "The password the app asks for."}
  ]

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
      auth = Application.get_env(:peon, :auth, "accounts")
      template_dir = Application.fetch_env!(:peon, :template_dir)
      {tree, blobs} = Template.instantiate(template_dir, otp_app, auth)
      {tree, blobs} = formatted(tree, blobs)
      {:ok, cs} = Store.import_tree(tree, blobs, slug, name, %{kind: :human, id: "burrow"})
      # Burrow starts new projects live-only ("live"); see Peon.Ship.
      Project.put_settings(%{"envs" => Application.get_env(:peon, :envs, "pipeline")})
      if auth == "basic", do: put_basic_auth()
      Logger.info("created #{slug} from the template (#{auth}) as changeset #{cs.id}")
    end
  after
    for {_secret, var, _why} <- @basic_auth, do: System.delete_env(var)
  end

  @doc false
  # The basic auth login Burrow passed becomes the app's secrets; what it
  # didn't pass is asked of the owner.
  def put_basic_auth do
    for {secret, var, why} <- @basic_auth,
        Secrets.put(secret, System.get_env(var), "burrow") != :ok,
        do: {:ok, _} = Secrets.request(secret, why, nil)

    :ok
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

    # Drops what the lock has only for left-out code (bcrypt, without accounts).
    script = "mix deps.unlock --unused && mix deps.get && mix format"

    case Sandbox.run(dir, script, env: %{"MIX_ENV" => "test"}) do
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
