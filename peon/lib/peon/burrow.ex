defmodule Peon.Burrow do
  @moduledoc """
  Burrow's API for this Peon (`:burrow_api`, with the `:api_token` both
  share). The workspace draws Burrow's side from it: the user's projects for
  the project rail (`rail/1`), this project's sharing, and new projects.
  Peon also reports what its project is doing (`report/1`, from
  `Peon.Activity`); Burrow tells Peon when a rail changed (`subscribe/0`).

  Without Burrow (`:burrow_api` unset) the rail is empty and the rest
  answers `{:error, message}`.
  """

  def subscribe, do: Phoenix.PubSub.subscribe(Peon.PubSub, "rail")

  @doc "Burrow said a project in a rail changed: workspaces fetch theirs again."
  def rail_changed, do: Phoenix.PubSub.broadcast(Peon.PubSub, "rail", :rail_changed)

  @doc """
  `%{projects: [%{id, name, slug, url, current, state, label, pct}],
  rail_open, theme, project}`, `project` being this one's sharing:
  `%{owner?, live_only?, team, teams, teammates}`.
  """
  def rail(email) do
    case request(:get, "/projects", params: [email: email]) do
      {:ok, %{status: 200, body: %{"projects" => projects} = body}} ->
        %{
          projects: Enum.map(projects, &project/1),
          rail_open: body["rail_open"] == true,
          theme: if(body["theme"] in ~w(system light dark), do: body["theme"]),
          project: sharing(body["project"] || %{})
        }

      _ ->
        %{projects: [], rail_open: false, theme: nil, project: nil}
    end
  end

  defp project(p) do
    %{
      id: p["id"],
      name: p["name"],
      slug: p["slug"],
      url: p["url"],
      current: p["current"] == true,
      state: p["state"] || "done",
      label: p["label"] || "",
      pct: p["pct"] || 100
    }
  end

  defp sharing(p) do
    %{
      owner?: p["owner"] == true,
      live_only?: p["live_only"] == true,
      team: p["team"] && %{id: p["team"]["id"], name: p["team"]["name"]},
      teams: for(t <- p["teams"] || [], do: %{id: t["id"], name: t["name"]}),
      teammates: for(u <- p["teammates"] || [], do: %{id: u["id"], email: u["email"]})
    }
  end

  @doc "Remembers, in Burrow, whether `email`'s rail shows project names."
  def put_rail_open(email, open?),
    do: post("/prefs", %{email: email, rail_open: open?})

  @doc "Sets `email`'s theme in Burrow: \"system\", \"light\" or \"dark\"."
  def put_theme(email, theme), do: post("/prefs", %{email: email, theme: theme})

  @doc "Creates a project for `email`; `{:ok, url}` opens it."
  def create_project(email, attrs) do
    case request(:post, "/projects", json: Map.put(attrs, "email", email)) do
      {:ok, %{status: 200, body: %{"url" => url}}} -> {:ok, url}
      other -> error(other)
    end
  end

  def share(email, team_id), do: post("/share", %{email: email, team_id: team_id})

  def hand_over(email, user_id), do: post("/hand-over", %{email: email, user_id: user_id})

  def add_envs(email), do: post("/add-envs", %{email: email}, 30_000)

  @doc "What this project is doing, for the rails (see `Burrow.Activity`)."
  def report(activity), do: post("/status", activity)

  defp post(path, body, timeout \\ 10_000) do
    case request(:post, path, json: body, receive_timeout: timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  defp error({:ok, %{body: %{"error" => message}}}), do: {:error, message}
  defp error({:ok, %{status: status}}), do: {:error, "Burrow answered #{status}."}
  defp error({:error, :no_burrow}), do: {:error, "This Peon runs without Burrow."}
  defp error({:error, _}), do: {:error, "Burrow did not answer."}

  defp request(method, path, opts) do
    case Application.get_env(:peon, :burrow_api) do
      api when is_binary(api) ->
        # Tests stand in for Burrow with `plug: {Req.Test, Peon.Burrow}`.
        [
          method: method,
          url: api <> path,
          auth: {:bearer, Application.get_env(:peon, :api_token)},
          retry: false,
          receive_timeout: 5_000
        ]
        |> Keyword.merge(opts)
        |> Keyword.merge(Application.get_env(:peon, :burrow_req, []))
        |> Req.request()

      _ ->
        {:error, :no_burrow}
    end
  end
end
