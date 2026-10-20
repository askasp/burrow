defmodule Burrow.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :port, :integer
    field :preview_ports, :string
    # "live" (main is live, no staging) or "pipeline" (staging and prod)
    field :envs, :string, default: "live"
    # An existing git repo to work on instead of a new app from the template
    field :repo_url, :string
    # The login a new app starts with (see `auths/0`); repo projects keep their own.
    field :auth, :string, default: "accounts"
    # For "basic": the login the app asks for. Never stored: Burrow hands it
    # to the project's Peon once (`Burrow.Cell`), which keeps it as secrets.
    field :basic_username, :string, virtual: true, redact: true
    field :basic_password, :string, virtual: true, redact: true
    belongs_to :user, Burrow.Accounts.User
    belongs_to :team, Burrow.Teams.Team
    timestamps(type: :utc_datetime)
  end

  @auths [
    {"User accounts (email and password)", "accounts"},
    {"One username and password (basic auth)", "basic"},
    {"Open: no login", "open"}
  ]

  @doc """
  The logins a new app can start with, as `{label, value}` (select options);
  the first is the default.
  """
  def auths, do: @auths

  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_url, :auth, :basic_username, :basic_password])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 60)
    |> validate_format(:name, ~r/[a-zA-Z]/, message: "must contain a letter")
    |> update_change(:repo_url, &String.trim/1)
    |> validate_format(:repo_url, ~r{\Ahttps://[^\s/]+/[^\s]+\z},
      message: "must be an https:// git URL"
    )
    |> validate_auth()
  end

  # A repo project keeps the repo's own login; the choice is for new apps.
  defp validate_auth(changeset) do
    cond do
      get_field(changeset, :repo_url) ->
        changeset
        |> delete_change(:auth)
        |> delete_change(:basic_username)
        |> delete_change(:basic_password)

      get_field(changeset, :auth) == "basic" ->
        changeset
        |> update_change(:basic_username, &String.trim/1)
        |> validate_required([:basic_username, :basic_password])
        |> validate_length(:basic_username, max: 100)
        |> validate_format(:basic_username, ~r/\A[^:[:cntrl:]]+\z/u,
          message: "can't have a colon"
        )
        |> validate_length(:basic_password, min: 8, max: 200)
        |> validate_format(:basic_password, ~r/\A[^[:cntrl:]]+\z/u,
          message: "can't have control characters"
        )

      true ->
        changeset
        |> validate_inclusion(:auth, Enum.map(@auths, &elem(&1, 1)))
        |> delete_change(:basic_username)
        |> delete_change(:basic_password)
    end
  end

  def shared?(%__MODULE__{team_id: team_id}), do: team_id != nil

  @doc "Made from an existing git repo: chats open PRs, there are no envs."
  def repo?(%__MODULE__{repo_url: url}), do: url not in [nil, ""]

  def live_only?(%__MODULE__{envs: envs} = project), do: envs == "live" and not repo?(project)

  @doc "The basic auth login to hand to the project's Peon, or nil."
  def basic_login(%__MODULE__{auth: "basic", basic_username: user, basic_password: pw})
      when is_binary(user) and is_binary(pw),
      do: {user, pw}

  def basic_login(%__MODULE__{}), do: nil
end
