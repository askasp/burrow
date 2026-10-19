defmodule Burrow.Inline do
  @moduledoc """
  A live-only project's inline chat, as its Peon reports it (`Peon.Inline`):
  the chat under the running app on the projects page.

  Peon pushes its state to `BurrowWeb.PeonController` whenever it changes;
  it is kept here and broadcast as `{:inline, project_id, state}` on topic
  `"inline"`. `fetch/1` asks Peon once, for a project Burrow has heard
  nothing from yet. Commands (`send_message/3`, `merge/2`, ...) go to Peon
  over HTTP, with the token Burrow and that Peon share (`token/1`).
  """

  use GenServer

  alias Burrow.Projects
  alias Burrow.Projects.Project

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "inline")

  @doc "The token Burrow and the project's Peon use with each other."
  def token(%Project{} = project), do: Projects.secret(project, "peon-api")

  @doc "Where the project's Peon pushes its state."
  def push_url(%Project{id: id}), do: internal_url() <> "/api/peon/#{id}/inline"

  @doc "The last state the project's Peon reported, or nil."
  def get(project_id) do
    case :ets.lookup(@table, project_id) do
      [{_, state}] -> state
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Keeps `state` unless a newer one (by `seq`) is kept already, and broadcasts it."
  def put(project_id, %{} = state) do
    GenServer.call(__MODULE__, {:put, project_id, state})
  end

  @doc "Forgets what the project's Peon reported, e.g. when the project is gone."
  def forget(project_id), do: GenServer.call(__MODULE__, {:forget, project_id})

  @doc false
  def forget_all, do: GenServer.call(__MODULE__, :forget_all)

  @doc "Asks the project's Peon for its state."
  def fetch(%Project{} = project) do
    case request(project, :get, "") do
      {:ok, state} -> {:ok, put(project.id, state)}
      error -> error
    end
  end

  def send_message(project, user, %{} = params),
    do: command(project, "send", Map.put(params, "user", user))

  def merge(project, user), do: command(project, "merge", %{"user" => user})

  def discard(project), do: command(project, "discard", %{})

  def add_envs(project, user), do: command(project, "add-envs", %{"user" => user})

  defp command(project, action, params) do
    case request(project, :post, "/" <> action, params) do
      {:ok, state} -> {:ok, put(project.id, state)}
      error -> error
    end
  end

  defp request(project, method, path, params \\ nil) do
    opts = [
      method: method,
      url: "http://#{peon_host()}:#{project.port}/api/inline#{path}",
      auth: {:bearer, token(project)},
      retry: false,
      receive_timeout: 15_000
    ]

    opts = if params, do: Keyword.put(opts, :json, params), else: opts
    # Tests stand in for Peon with `plug: {Req.Test, Burrow.Inline}`.
    opts = Keyword.merge(opts, Application.get_env(:burrow, :inline_req, []))

    case Req.request(opts) do
      {:ok, %{status: 200, body: %{} = state}} -> {:ok, state}
      {:ok, %{body: %{"error" => message}}} -> {:error, message}
      {:ok, %{status: status}} -> {:error, "Peon answered #{status}."}
      {:error, _} -> {:error, "Peon isn't running."}
    end
  end

  # Burrow runs the Peons itself (`Burrow.Cell`), so both sides are local.
  defp peon_host, do: Application.get_env(:burrow, :peon_internal_host, "127.0.0.1")

  defp internal_url do
    Application.get_env(:burrow, :internal_url) ||
      "http://127.0.0.1:#{Application.get_env(:burrow, BurrowWeb.Endpoint)[:http][:port] || 4000}"
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:forget, id}, _from, nil) do
    :ets.delete(@table, id)
    {:reply, :ok, nil}
  end

  def handle_call(:forget_all, _from, nil) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, nil}
  end

  def handle_call({:put, id, state}, _from, nil) do
    kept = get(id)

    if kept && (kept["seq"] || 0) > (state["seq"] || 0) do
      {:reply, kept, nil}
    else
      :ets.insert(@table, {id, state})
      Phoenix.PubSub.broadcast(Burrow.PubSub, "inline", {:inline, id, state})
      {:reply, state, nil}
    end
  end
end
