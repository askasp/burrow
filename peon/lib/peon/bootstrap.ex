defmodule Peon.Bootstrap do
  @moduledoc """
  On first boot, creates the project from the template as changeset 1, with
  the login Burrow picked (`Peon.Instance` `:auth`, see `Peon.Template`).
  Runs once during startup, before checks and previews start.

  For `"basic"`, Burrow passes the username and password on the first start
  (`:basic_auth`); they become the app's secrets `BASIC_AUTH_USERNAME` and
  `BASIC_AUTH_PASSWORD`. Without them the owner is asked to set those secrets.
  """

  require Logger

  alias Peon.{Code, Project, Sandbox, Secrets, Store, Template}

  @basic_auth [
    {"BASIC_AUTH_USERNAME", "The username the app asks for."},
    {"BASIC_AUTH_PASSWORD", "The password the app asks for."}
  ]

  def child_spec(instance), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [instance]}}

  # Runs synchronously so later children see the imported project.
  def start_link(instance) do
    Peon.Instance.put(instance)
    run()
    :ignore
  end

  def run do
    Peon.Sandbox.remove_all()

    if Code.ref("main") == nil and Application.get_env(:peon, :template_dir) do
      slug = Peon.Instance.fetch!(:slug)
      name = Peon.Instance.fetch!(:name)
      otp_app = Template.otp_app(slug)
      auth = Peon.Instance.fetch!(:auth)
      template_dir = Application.fetch_env!(:peon, :template_dir)
      {tree, blobs} = Template.instantiate(template_dir, otp_app, auth)
      {tree, blobs} = formatted(tree, blobs)
      {:ok, cs} = Store.import_tree(tree, blobs, slug, name, %{kind: :human, id: "burrow"})
      # Burrow starts new projects live-only ("live"); see Peon.Ship.
      Project.put_settings(%{"envs" => Peon.Instance.fetch!(:envs)})
      if auth == "basic", do: put_basic_auth(Peon.Instance.fetch!(:basic_auth))
      Peon.Chats.create_first()
      Logger.info("created #{slug} from the template (#{auth}) as changeset #{cs.id}")
    end
  end

  @doc false
  # The basic auth login Burrow passed (`{username, password}`) becomes the
  # app's secrets; what it didn't pass is asked of the owner.
  def put_basic_auth(login) do
    values = Tuple.to_list(login || {nil, nil})

    for {{secret, why}, value} <- Enum.zip(@basic_auth, values),
        Secrets.put(secret, value, "burrow") != :ok,
        do: {:ok, _} = Secrets.request(secret, why, nil)

    :ok
  end

  # Renaming the template's modules changes line lengths, so the new project
  # is run through `mix format` once; otherwise the first `mix format` in any
  # chat would rewrite files it never meant to touch. Unchanged on failure.
  defp formatted(tree, blobs) do
    dir = Path.join(Peon.Instance.fetch!(:data_dir), "bootstrap")
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
        Totem.Tree.from_dir(dir, Peon.Ignore.matcher(dir))

      {status, output, _ms} ->
        Logger.warning("could not format the new project (#{inspect(status)}): #{output}")
        {tree, blobs}
    end
  after
    File.rm_rf(Path.join(Peon.Instance.fetch!(:data_dir), "bootstrap"))
  end
end
