defmodule Burrow.Bootstrap do
  @moduledoc """
  A new project's first change: the template app (`Burrow.Template`) with the
  login the owner picked, run through `mix format` once (renaming the
  template's modules changes line lengths), as change #1 of its history. A
  `"basic"` login becomes the app's secrets `BASIC_AUTH_USERNAME` and
  `BASIC_AUTH_PASSWORD`; without them the owner is asked for them. With
  `"accounts"`, `signups` picks whether anyone can sign up or only the
  people the first account (the admin) adds.
  """

  require Logger

  alias Burrow.{BuildCache, Chats, Projects, Sandbox, Secrets, Template, Workspace}

  @basic_auth [
    {"BASIC_AUTH_USERNAME", "The username the app asks for."},
    {"BASIC_AUTH_PASSWORD", "The password the app asks for."}
  ]

  def run(project) do
    repo = Projects.repo_dir(project)

    if Totem.Repo.empty?(repo) and not Projects.Project.repo?(project) do
      otp_app = Template.otp_app(project.slug)

      {tree, blobs} =
        Template.instantiate(
          Application.fetch_env!(:burrow, :template_dir),
          otp_app,
          project.auth,
          signups: project.signups == true
        )

      {tree, blobs} = formatted(project, tree, blobs)
      {:ok, change} = Totem.Repo.init(repo, tree, blobs, "Create #{project.name}", "burrow")
      if project.auth == "basic", do: put_basic_auth(project)
      Logger.info("created #{project.slug} from the template (#{project.auth}) as ##{change.id}")
    end

    if Chats.list(project.id) == [], do: Chats.create_empty(project.id, "peon")
    :ok
  end

  defp put_basic_auth(project) do
    values = Tuple.to_list(Projects.Project.basic_login(project) || {nil, nil})

    for {{name, why}, value} <- Enum.zip(@basic_auth, values),
        Secrets.put(project.id, name, value, "burrow") != :ok,
        do: {:ok, _} = Secrets.request(project.id, name, why, nil)
  end

  # Unchanged when formatting fails.
  defp formatted(project, tree, blobs) do
    dir = Path.join(Projects.dir(project), "bootstrap")
    File.rm_rf!(dir)

    for {path, hash} <- tree do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), Map.fetch!(blobs, hash))
    end

    BuildCache.seed(dir)

    # Drops what the lock has only for left-out code (bcrypt, without accounts).
    script = "mix deps.unlock --unused && mix deps.get && mix format"

    case Sandbox.run(dir, script, project: project.slug, env: %{"MIX_ENV" => "test"}) do
      {0, _output, _ms} ->
        Totem.Tree.from_dir(dir, Workspace.ignore(dir))

      {status, output, _ms} ->
        Logger.warning("could not format #{project.slug} (#{inspect(status)}): #{output}")
        {tree, blobs}
    end
  after
    File.rm_rf(Path.join(Projects.dir(project), "bootstrap"))
  end
end
