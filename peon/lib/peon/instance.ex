defmodule Peon.Instance do
  @moduledoc """
  One project's Peon. Burrow runs one instance per project in its own BEAM
  (`start_link/1`); each is a supervision tree with its own database, store,
  checks, environments and chats.

  Every process working for a project carries its instance (`put/1`): that
  picks its database (`Peon.Repo` is a dynamic repo, one per project), and
  scopes its names (`via/1`) and PubSub topics (`topic/1`). Processes of the
  tree put it when they start; anything else, such as a LiveView or a task,
  puts it first (`run/2`, `bind/1`).

  Settings that are the same for every project (the template, the sandbox
  image, where a browser reaches a port) stay in the `:peon` app env.
  """

  @enforce_keys [:id, :slug, :name, :data_dir]
  defstruct [
    :id,
    :slug,
    :name,
    :data_dir,
    # A repo project's `%{url, branch}` (`Peon.Source`), nil for a new app
    repo: nil,
    # Host ports for chat previews, and for staging and prod
    preview_ports: [],
    env_ports: %{},
    # What a new project starts as: "live" (main is live) or "pipeline"
    envs: "pipeline",
    # The login a new app starts with: "accounts", "basic" or "open"
    auth: "accounts",
    # For "basic", the `{username, password}` Burrow passes on the first start
    basic_auth: nil,
    # The agent's default model and the owner's opencode login
    opencode_model: nil,
    opencode_data_dir: nil,
    # Signs the agent's MCP tokens
    secret: nil,
    # The database: `Peon.Repo` in tests, else a repo of its own
    db: Peon.Repo
  ]

  @type t :: %__MODULE__{}

  @key :peon_instance

  @doc "A new instance; `:db` defaults to a repo of its own."
  def new(attrs) do
    attrs = Map.new(attrs)
    struct!(__MODULE__, Map.put_new(attrs, :db, :"Peon.Repo.#{attrs.id}"))
  end

  @doc "Starts the instance's tree. Blocks while a new project is created from the template."
  def start_link(%__MODULE__{} = instance), do: Peon.Instance.Supervisor.start_link(instance)

  def child_spec(%__MODULE__{} = instance),
    do: %{
      id: {__MODULE__, instance.id},
      start: {__MODULE__, :start_link, [instance]},
      type: :supervisor
    }

  @doc "The running instance with `id`, once its tree is up; else nil."
  def lookup(id) do
    case Registry.lookup(Peon.Registry, {id, :ready}) do
      [{_pid, instance}] -> instance
      [] -> nil
    end
  end

  @doc "Makes `instance` this process's project."
  def put(%__MODULE__{} = instance) do
    Process.put(@key, instance)
    Peon.Repo.put_dynamic_repo(instance.db)
    instance
  end

  @doc "This process's instance, or nil."
  def current, do: Process.get(@key)

  def current! do
    current() || raise "this process works for no Peon instance (see Peon.Instance.put/1)"
  end

  @doc "A field of this process's instance."
  def fetch!(key), do: Map.fetch!(current!(), key)

  @doc "Runs `fun` as the running instance `id`: `{:error, :not_running}` when it isn't."
  def run(id, fun) do
    case lookup(id) do
      nil ->
        {:error, :not_running}

      instance ->
        previous = current()
        put(instance)

        try do
          fun.()
        after
          if previous, do: put(previous), else: Process.delete(@key)
        end
    end
  end

  @doc "`fun` (arity 0 or 1) as this instance, for a task or another process."
  def bind(fun) when is_function(fun, 0) do
    instance = current!()

    fn ->
      put(instance)
      fun.()
    end
  end

  def bind(fun) when is_function(fun, 1) do
    instance = current!()

    fn arg ->
      put(instance)
      fun.(arg)
    end
  end

  @doc "A process name (`{:via, Registry, _}`) within this instance."
  def via(name), do: via(current!(), name)

  def via(%__MODULE__{id: id}, name), do: {:via, Registry, {Peon.Registry, {id, name}}}

  def whereis(name), do: GenServer.whereis(via(name))

  @doc "A PubSub topic of this instance."
  def topic(name), do: "peon:#{current!().id}:#{name}"

  def subscribe(name), do: Phoenix.PubSub.subscribe(Peon.PubSub, topic(name))

  def unsubscribe(name), do: Phoenix.PubSub.unsubscribe(Peon.PubSub, topic(name))

  def broadcast(name, message), do: Phoenix.PubSub.broadcast(Peon.PubSub, topic(name), message)

  @doc """
  The topic every instance reports its project's activity on, for Burrow's
  project rail: `{:activity, id, activity}` (`Peon.Activity`).
  """
  def activity_topic, do: "peon:activity"
end
