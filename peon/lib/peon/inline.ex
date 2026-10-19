defmodule Peon.Inline do
  @moduledoc """
  The inline chat: the chat Burrow's project page shows under the running app
  of a live-only project, so a change can be asked for, checked, previewed
  and merged without opening the workspace. It is a normal chat (it is in
  the workspace's list, which can continue it); the project setting
  `"inline_chat"` names it until its changeset is discarded.

  Burrow gets the state (`state/0`) pushed: whenever the chat, its
  changeset, its checks or prod change, it is posted to `:burrow_api` with
  the `:api_token`. A push carries `seq`, which only grows, so Burrow can
  drop one that arrives late.

  The state's `"changeset"` has a `"phase"`:

    * `"writing"` - the agent works and hasn't submitted (yet)
    * `"checking"` - the checks run (`"steps"` says which)
    * `"failed"` - a check failed and the agent stopped
    * `"ready"` - passed; it waits for a human to merge it
    * `"landing"` - merged; prod is deploying it
    * `"live"` - prod runs it
    * `"deploy_failed"` - prod could not run it and went back
  """

  use GenServer

  require Logger

  alias Peon.{Chat, Chats, Checks, Code, Env, Project, Ship, Store}

  @steps ~w(deps compile format test)
  @messages 80
  @debounce 150

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## API

  def chat_id, do: Project.settings()["inline_chat"]

  @doc "The state Burrow shows (see the moduledoc)."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc """
  Sends `text` in the inline chat as `user`. It starts a new chat when there
  is none or its change is on main already; `opts` are
  `Peon.Chats.create/3`'s, for that chat.
  """
  def send_message(text, user, opts \\ []),
    do: GenServer.call(__MODULE__, {:send, String.trim(text), user, opts})

  @doc "Merges the inline chat's passed changeset as `user`; on a live-only project it goes live."
  def merge(user), do: GenServer.call(__MODULE__, {:merge, user})

  @doc "Drops the inline chat's open changeset and ends the inline chat."
  def discard, do: GenServer.call(__MODULE__, :discard)

  @doc "Turns the project into one with staging and prod (`Peon.Ship.add_envs/1`)."
  def add_envs(user), do: GenServer.call(__MODULE__, {:add_envs, user})

  @doc "Whether chat `id`'s containers must stay up: it is the inline chat and its changeset is open."
  def keep_alive?(id) do
    id == chat_id() and
      match?(%{status: s} when s in ~w(proposed checking passed), Chats.draft(id))
  end

  ## Server

  @impl true
  def init(_opts) do
    Store.subscribe()
    Checks.subscribe()
    Env.subscribe()

    state = %{
      chat: nil,
      info: nil,
      monitor: nil,
      pending: nil,
      error: nil,
      steps: %{},
      starting: false,
      prod: Env.info("prod"),
      timer: nil,
      pushed: nil
    }

    {:ok, state |> follow(chat_id()) |> schedule()}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, build(state), state}

  def handle_call({:send, "", _user, _opts}, _from, state), do: {:reply, {:error, :empty}, state}

  def handle_call({:send, text, user, opts}, _from, state) do
    cond do
      state.pending || (state.info && state.info.busy?) ->
        {:reply, {:error, :busy}, state}

      true ->
        chat = continuing(state.chat) || Chats.create(text, user, opts)
        if chat.id != state.chat, do: Project.put_settings(%{"inline_chat" => chat.id})
        state = follow(state, chat.id)
        me = self()

        Task.Supervisor.start_child(Peon.TaskSupervisor, fn ->
          send(me, {:sent, chat.id, Chat.send_message(chat.id, text)})
        end)

        {:reply, {:ok, chat.id}, schedule(%{state | pending: text, error: nil})}
    end
  end

  def handle_call({:merge, user}, _from, state) do
    reply =
      case state.chat && Chats.draft(state.chat) do
        %{status: "passed"} = cs -> Ship.merge(cs.id, user)
        _ -> {:error, :nothing_to_merge}
      end

    {:reply, reply, schedule(state)}
  end

  def handle_call(:discard, _from, state) do
    with id when id != nil <- state.chat,
         %{} = cs <- Chats.draft(id) do
      Store.supersede(cs.id)
    end

    Project.put_settings(%{"inline_chat" => nil})
    {:reply, :ok, state |> follow(nil) |> schedule()}
  end

  def handle_call({:add_envs, user}, _from, state) do
    Ship.add_envs(user)
    {:reply, :ok, schedule(state)}
  end

  @impl true
  def handle_info({:messages, messages}, state),
    do: {:noreply, state |> put_info(%{messages: messages}) |> schedule()}

  def handle_info({:status, status}, state) do
    state = state |> watch_chat() |> put_info(status)
    # The agent took the prompt: it is the chat's now.
    state = if status.busy?, do: %{state | pending: nil}, else: state
    {:noreply, schedule(state)}
  end

  def handle_info({:sent, id, result}, %{chat: id} = state) do
    case result do
      :ok -> {:noreply, state |> watch_chat() |> schedule()}
      {:error, reason} -> {:noreply, schedule(%{state | pending: nil, error: describe(reason)})}
    end
  end

  def handle_info({:sent, _id, _result}, state), do: {:noreply, state}

  def handle_info({:started, id, result}, state) do
    state = %{state | starting: false}

    case result do
      {:ok, info} when id == state.chat ->
        {:noreply, state |> watch_chat() |> put_info(info) |> schedule()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, schedule(%{state | monitor: nil, info: nil})}

  def handle_info({:check_step, id, name, status}, state),
    do:
      {:noreply,
       schedule(%{
         state
         | steps: Map.update(state.steps, id, %{name => status}, &Map.put(&1, name, status))
       })}

  def handle_info({:env, "prod", info}, state), do: {:noreply, schedule(%{state | prod: info})}

  def handle_info(:push, state) do
    snapshot = build(state)
    state = %{state | timer: nil}

    # Stats change every few seconds; push only what Burrow shows.
    if Map.delete(snapshot, "seq") == state.pushed,
      do: {:noreply, state},
      else: {:noreply, push(state, snapshot)}
  end

  def handle_info(_msg, state), do: {:noreply, schedule(state)}

  # A message continues the inline chat until its change is on main; the next
  # change gets a chat of its own (with that message's model and effort).
  defp continuing(nil), do: nil

  defp continuing(id) do
    main = Code.ref("main")

    case Chats.get(id) && Chats.latest_changeset(id) do
      nil -> Chats.get(id)
      cs -> if Code.ancestor?(cs.id, main.changeset_id), do: nil, else: Chats.get(id)
    end
  end

  ## Following the chat

  defp follow(%{chat: id} = state, id), do: state

  defp follow(state, id) do
    if state.chat, do: Phoenix.PubSub.unsubscribe(Peon.PubSub, "chat:#{state.chat}")
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    state = %{state | chat: id, info: nil, monitor: nil, pending: nil, error: nil}

    if id && Chats.get(id) do
      Chat.subscribe(id)

      case Chat.info(id) do
        {:ok, info} -> state |> watch_chat() |> put_info(info)
        _ -> state
      end
    else
      %{state | chat: nil}
    end
  end

  # Notices when the chat's process stops (idle, crash): its preview is gone.
  defp watch_chat(%{monitor: nil, chat: id} = state) when id != nil do
    case Registry.lookup(Peon.ChatRegistry, id) do
      [{pid, _}] -> %{state | monitor: Process.monitor(pid)}
      [] -> state
    end
  end

  defp watch_chat(state), do: state

  defp put_info(state, changes) do
    info = Map.merge(state.info || %{busy?: false, messages: []}, Map.new(changes))
    %{state | info: info}
  end

  ## Pushing

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :push, @debounce)}

  defp schedule(state), do: state

  defp push(state, snapshot) do
    url = Application.get_env(:peon, :burrow_api)
    token = Application.get_env(:peon, :api_token)

    if url && token do
      Task.Supervisor.start_child(Peon.TaskSupervisor, fn ->
        case Req.post(url,
               json: snapshot,
               auth: {:bearer, token},
               retry: false,
               receive_timeout: 5_000
             ) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          other -> Logger.info("Burrow did not take the inline state: #{inspect(other)}")
        end
      end)
    end

    state = maybe_start_chat(state, snapshot)
    %{state | pushed: Map.delete(snapshot, "seq")}
  end

  # A ready changeset's dev preview must be up, e.g. after Peon restarted.
  defp maybe_start_chat(%{starting: false, info: nil, chat: id} = state, %{
         "changeset" => %{"phase" => "ready"}
       })
       when id != nil do
    me = self()

    Task.Supervisor.start_child(Peon.TaskSupervisor, fn ->
      send(me, {:started, id, Chat.ensure_started(id)})
    end)

    %{state | starting: true}
  end

  defp maybe_start_chat(state, _snapshot), do: state

  ## The state

  defp build(state) do
    prod = Code.ref("prod")
    live = prod && prod.changeset_id
    chat = state.chat && Chats.get(state.chat)
    busy? = state.pending != nil or (state.info != nil and state.info.busy? == true)
    changeset = chat && changeset(chat.id, busy?, live, state)

    %{
      "seq" => System.os_time(:microsecond),
      "mode" => if(Ship.live_only?(), do: "live", else: "pipeline"),
      "main" => with(%{changeset_id: id} <- Code.ref("main"), do: id),
      "live" => %{
        "tip" => live,
        # The last version prod ran healthy; nil until the first deploy is through.
        "good" => state.prod && state.prod.good,
        "url" => env_url("prod"),
        "status" => prod_status(state.prod, live)
      },
      "chat" => chat && chat_state(chat, state, busy?, changeset),
      "changeset" => changeset
    }
  end

  # The chat shows while it has something to show: it runs, it is starting,
  # or its changeset is still on its way.
  defp chat_state(chat, state, busy?, changeset) do
    shown? =
      busy? or state.info != nil or state.error != nil or
        (changeset != nil and changeset["phase"] in ~w(checking ready landing))

    if shown? do
      info = state.info || %{}
      messages = (info[:messages] || []) |> Enum.take(-@messages) |> Enum.map(&message/1)

      messages =
        if state.pending,
          do: messages ++ [%{"role" => "user", "text" => state.pending}],
          else: messages

      %{
        "id" => chat.id,
        "title" => chat.title,
        "busy" => busy?,
        "model" => chat.model,
        "effort" => chat.effort,
        "messages" => messages,
        "error" => state.error,
        "preview_url" => info[:preview_url],
        "preview_status" => info[:preview_status] && to_string(info[:preview_status])
      }
    end
  end

  defp message(m) do
    %{"role" => to_string(m.role), "text" => m.text}
    |> then(&if(m[:status], do: Map.put(&1, "status", to_string(m.status)), else: &1))
  end

  defp changeset(chat_id, busy?, live, state) do
    cs = Chats.latest_changeset(chat_id)
    main = Code.ref("main")
    landed? = cs != nil and main != nil and Code.ancestor?(cs.id, main.changeset_id)

    phase =
      cond do
        cs == nil -> if busy?, do: "writing"
        cs.status in ~w(proposed checking) -> "checking"
        cs.status == "passed" and not landed? -> "ready"
        busy? -> "writing"
        cs.status == "failed" -> "failed"
        not landed? -> nil
        Env.failed_deploy?("prod", cs.id) and live != cs.id -> "deploy_failed"
        live == cs.id and deploying?(state.prod, cs.id) -> "landing"
        live == cs.id -> "live"
        live && Code.ancestor?(cs.id, live) -> "live"
        true -> "landing"
      end

    if phase do
      cs = if phase == "writing", do: nil, else: cs

      %{
        "id" => cs && cs.id,
        "intent" => cs && cs.intent,
        "status" => cs && cs.status,
        "phase" => phase,
        "steps" => steps(cs, phase, state.steps),
        "deploy" => if(phase == "landing", do: deploy_phase(state.prod))
      }
    end
  end

  # The four checks, each "passed", "failed", "running" or "waiting".
  defp steps(nil, _phase, _seen), do: Enum.map(@steps, &%{"name" => &1, "status" => "waiting"})

  defp steps(cs, phase, seen) do
    done =
      case cs.checks do
        %{"steps" => [_ | _] = steps} -> Map.new(steps, &{&1["name"], &1["status"]})
        _ -> Map.get(seen, cs.id, %{})
      end

    {steps, _} =
      Enum.map_reduce(@steps, false, fn name, running? ->
        cond do
          status = done[name] -> {%{"name" => name, "status" => status}, running?}
          phase == "checking" and not running? -> {%{"name" => name, "status" => "running"}, true}
          true -> {%{"name" => name, "status" => "waiting"}, running?}
        end
      end)

    steps
  end

  defp deploying?(%{deploy: %{target: id}}, id), do: true
  defp deploying?(%{good: good}, id), do: good != id
  defp deploying?(_info, _id), do: true

  defp deploy_phase(%{deploy: %{phase: phase}}) when phase != nil, do: to_string(phase)
  defp deploy_phase(_info), do: "starting"

  defp prod_status(_info, nil), do: "not_built"
  defp prod_status(%{deploy: %{}}, _live), do: "building"
  defp prod_status(%{status: :running}, _live), do: "running"

  defp prod_status(%{status: status}, _live)
       when status in [:booting, :loading, :watching, :attaching],
       do: "building"

  defp prod_status(_info, _live), do: "stopped"

  defp env_url(name) do
    case Application.get_env(:peon, :env_ports, %{}) do
      %{^name => port} -> Peon.Ports.url(port)
      _ -> nil
    end
  end

  defp describe(:no_free_preview_port), do: "Every preview slot is in use by another chat."

  defp describe({:session, _}),
    do: "The agent could not open a session. Is an AI provider connected in Burrow?"

  defp describe(reason), do: "The agent could not start: #{inspect(reason)}"
end
