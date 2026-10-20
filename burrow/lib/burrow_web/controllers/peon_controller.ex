defmodule BurrowWeb.PeonController do
  @moduledoc """
  Each project's Peon, with the token it shares with Burrow
  (`Burrow.PeonAPI`). Its workspace draws Burrow's side from here: the
  project rail, the project's sharing, and new projects. Peon passes the
  signed-in user's `email`; they must be able to open this project.
  """

  use BurrowWeb, :controller

  alias Burrow.{Accounts, Activity, PeonAPI, Projects, Teams}
  alias Burrow.Accounts.Scope
  alias Burrow.Projects.Project

  plug :authorize when action != :status
  plug :authorize_peon when action == :status

  @doc "The projects the user can open (the rail), and this project's sharing."
  def projects(conn, _params) do
    %{project: project, scope: scope} = conn.assigns

    json(conn, %{
      "projects" =>
        for p <- conn.assigns.projects do
          Map.merge(Activity.of(p.id), %{
            "id" => p.id,
            "name" => p.name,
            "slug" => p.slug,
            "url" => url(~p"/projects/#{p.id}/open"),
            "current" => p.id == project.id
          })
        end,
      "rail_open" => scope.user.rail_open,
      "theme" => scope.user.theme,
      "project" => %{
        "owner" => Projects.owner?(scope, project),
        "live_only" => Project.live_only?(project),
        "team" => project.team && %{"id" => project.team.id, "name" => project.team.name},
        "teams" => for(t <- Teams.list(scope), do: %{"id" => t.id, "name" => t.name}),
        "teammates" => for(u <- teammates(project), do: %{"id" => u.id, "email" => u.email})
      }
    })
  end

  defp teammates(%Project{team: %Teams.Team{} = team, user_id: owner_id}),
    do: for(m <- Teams.members(team), m.user_id != owner_id, do: m.user)

  defp teammates(_project), do: []

  @doc "Remembers whether the rail shows project names, and the user's theme."
  def prefs(conn, params) do
    user = conn.assigns.scope.user
    if is_boolean(params["rail_open"]), do: Accounts.put_rail_open(user, params["rail_open"])

    case params["theme"] && Accounts.put_theme(user, params["theme"]) do
      {:error, _} -> error(conn, "Pick system, light or dark.")
      _ -> send_resp(conn, 204, "")
    end
  end

  @doc "A new project from the workspace's dialog; answers where to open it."
  def create(conn, params) do
    attrs = Map.take(params, ~w(name repo_url team_id auth basic_username basic_password))

    case Projects.create(conn.assigns.scope, attrs) do
      {:ok, project} ->
        json(conn, %{"id" => project.id, "url" => url(~p"/projects/#{project.id}/open")})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{"error" => first_error(changeset)})
    end
  end

  def share(conn, %{"team_id" => team_id}) do
    %{project: project, scope: scope} = conn.assigns

    case Projects.share(scope, project, team_id) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, :not_owner} -> error(conn, "Only the project's owner can share it.")
      {:error, _} -> error(conn, "That isn't one of your teams.")
    end
  end

  # Handing over restarts this Peon on the new owner's AI login, so it
  # happens after the answer.
  def hand_over(conn, %{"user_id" => user_id}) do
    %{project: project, scope: scope} = conn.assigns

    user_id =
      case Integer.parse(to_string(user_id)) do
        {id, ""} -> id
        _ -> nil
      end

    cond do
      not Projects.owner?(scope, project) ->
        error(conn, "Only the project's owner can hand it over.")

      project.team_id == nil or user_id in [nil, project.user_id] or
          not Teams.member_id?(project.team_id, user_id) ->
        error(conn, "Hand it to someone in the team it is shared with.")

      true ->
        Task.start(fn -> Projects.hand_over(scope, project, user_id) end)
        send_resp(conn, 202, "")
    end
  end

  def add_envs(conn, _params) do
    case Projects.add_envs(conn.assigns.scope, conn.assigns.project) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, :not_owner} -> error(conn, "Only the project's owner can add staging and prod.")
      {:error, message} -> error(conn, message)
    end
  end

  @doc "The Peon reports what its project is doing (`Burrow.Activity`)."
  def status(conn, %{"state" => state, "label" => label} = params)
      when state in ~w(working waiting done stopped) and is_binary(label) do
    pct = if is_integer(params["pct"]), do: min(max(params["pct"], 0), 100), else: 100

    Activity.put(conn.assigns.project.id, %{
      "state" => state,
      "label" => String.slice(label, 0, 40),
      "pct" => pct
    })

    send_resp(conn, 204, "")
  end

  defp error(conn, message), do: conn |> put_status(422) |> json(%{"error" => message})

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, &translate/1) |> Enum.at(0) do
      {field, [message | _]} -> "#{Phoenix.Naming.humanize(field)} #{message}"
      _ -> "Could not create the project."
    end
  end

  defp translate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  # The Peon's token, and a user who can open its project.
  defp authorize(conn, _opts) do
    with %{} = project <- peon_project(conn),
         email when is_binary(email) <- conn.params["email"],
         %{} = user <- Accounts.get_user_by_email(email),
         scope = Scope.for_user(user),
         projects = Projects.list(scope),
         %{} = project <- Enum.find(projects, &(&1.id == project.id)) do
      assign(conn, project: project, scope: scope, projects: projects)
    else
      _ -> unauthorized(conn)
    end
  end

  defp authorize_peon(conn, _opts) do
    case peon_project(conn) do
      %{} = project -> assign(conn, :project, project)
      nil -> unauthorized(conn)
    end
  end

  defp peon_project(conn) do
    with {id, ""} <- Integer.parse(conn.params["id"] || ""),
         %{} = project <- Projects.get(id),
         "Bearer " <> given <- conn |> get_req_header("authorization") |> List.first(""),
         true <- Plug.Crypto.secure_compare(given, PeonAPI.token(project)) do
      project
    else
      _ -> nil
    end
  end

  defp unauthorized(conn),
    do: conn |> put_status(401) |> json(%{"error" => "unauthorized"}) |> halt()
end
