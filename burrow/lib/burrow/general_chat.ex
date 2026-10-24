defmodule Burrow.GeneralChat do
  @moduledoc """
  The process behind one general chat (`Burrow.GeneralChats`): an opencode
  agent in a container of its own, with the user's opencode login and
  nothing to work on but the web (opencode's websearch and webfetch). It
  answers, searches and thinks; it can't read or change files or run
  commands.

  While the agent works this process polls the session and broadcasts on
  the chat's topic (`Burrow.GeneralChats.subscribe_chat/1`):

    * `{:messages, messages}` - the conversation, normalized as in `Burrow.Chat`
    * `{:status, status}` - see `info/1`

  and keeps a copy of the conversation with the chat. It stops after
  `@idle_timeout` without use (`{:stopped, :idle}`); the next message starts
  it again. Runs under `Burrow.ChatSupervisor`, registered in
  `Burrow.ChatRegistry` as `{{:general, user_id}, id}`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Burrow.{GeneralChats, Sandbox}
  alias Burrow.GeneralChats.Sources
  alias Burrow.OpenCode.Client

  @registry Burrow.ChatRegistry
  @idle_timeout :timer.minutes(15)
  @boot_timeout :timer.seconds(90)
  @poll_interval 1_200
  # With web search off for a message; the thread doesn't show it.
  # After each message, as in `Burrow.Chat`: the instructions alone don't
  # get every model to answer short and cite. The thread doesn't show them.
  @cite_hint "\n\n(Peon: answer short, without headings; mark what comes from a page with [1], [2] and end with the Sources: block, as your instructions say.)"
  @no_web "\n\n(Peon: answer from what you know this time; don't search the web.)"
  @web_tools ~w(websearch webfetch)

  ## API

  @doc "Starts the chat's agent if needed and waits until it is ready."
  def ensure_started(%GeneralChats.Chat{} = chat) do
    case DynamicSupervisor.start_child(Burrow.ChatSupervisor, {__MODULE__, chat}) do
      {:ok, pid} ->
        GenServer.call(pid, :await_ready, @boot_timeout + 5_000)

      {:error, {:already_started, pid}} ->
        GenServer.call(pid, :await_ready, @boot_timeout + 5_000)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Sends the user's message with `files` (`%{name, mime}`, in `GeneralChats.files_dir/1`)."
  def send_message(chat, text, files \\ []) do
    with {:ok, _info} <- ensure_started(chat), do: call(chat.id, {:prompt, text, files})
  end

  @doc """
  `%{agent_status, busy?, messages, pages}`: `pages` are what the agent
  searched and read in the turn so far (`Burrow.GeneralChats.Sources.pages/1`).
  """
  def info(id), do: call(id, :info)

  def interrupt(id), do: call(id, :interrupt)

  @doc "Stops the chat's agent, if it runs."
  def stop(id) do
    if pid = whereis(id), do: GenServer.stop(pid, :normal, :timer.seconds(30))
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Removes the agents a previous run of Burrow left behind; they start again when used."
  def remove_left_behind do
    {ids, _} = System.cmd("docker", ["ps", "-aq", "--filter", "label=burrow.general"])

    case String.split(ids) do
      [] -> :ok
      ids -> System.cmd("docker", ["rm", "-f" | ids], stderr_to_stdout: true)
    end

    :ok
  end

  @doc "The user's general chats whose agent is working right now."
  def busy_ids(user_id) do
    Registry.select(@registry, [{{{{:general, user_id}, :"$1"}, :_, %{busy?: true}}, [], [:"$1"]}])
    |> MapSet.new()
  end

  defp whereis(id) do
    case Registry.select(@registry, [{{{{:general, :_}, id}, :"$1", :_}, [], [:"$1"]}]) do
      [pid] -> pid
      [] -> nil
    end
  end

  defp call(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg, 30_000)
    end
  end

  def child_spec(chat),
    do: %{
      id: {__MODULE__, chat.id},
      start: {__MODULE__, :start_link, [chat]},
      restart: :temporary
    }

  def start_link(chat),
    do:
      GenServer.start_link(__MODULE__, chat,
        name: {:via, Registry, {@registry, {{:general, chat.user_id}, chat.id}, %{busy?: false}}}
      )

  ## Server

  @impl true
  def init(chat) do
    Process.flag(:trap_exit, true)
    base = GeneralChats.dir(chat)

    state = %{
      id: chat.id,
      user_id: chat.user_id,
      base: base,
      agent: %{
        name: "peon-ask-#{chat.user_id}-#{chat.id}",
        port: free_port(),
        password: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
        container: nil,
        status: :starting
      },
      session_id: nil,
      busy?: false,
      told_busy?: false,
      prompted_at: 0,
      messages: GeneralChats.messages(chat),
      pages: [],
      waiting: [],
      booted_at: System.monotonic_time(:millisecond),
      idle_ref: nil,
      stopped: :exited
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    send(self(), :wait_agent)
    {:noreply, state |> start_agent() |> touch()}
  end

  @impl true
  def handle_call(:await_ready, from, %{agent: %{status: :starting}} = state),
    do: {:noreply, %{state | waiting: [from | state.waiting]}}

  def handle_call(:await_ready, _from, state), do: {:reply, ready_reply(state), touch(state)}

  def handle_call({:prompt, text, files}, _from, state), do: prompt(state, text, files)

  def handle_call(:info, _from, state), do: {:reply, {:ok, info_map(state)}, state}

  def handle_call(:interrupt, _from, state) do
    Client.interrupt(conn(state), state.session_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:wait_agent, state) do
    cond do
      Client.ready?(conn(state)) ->
        case ensure_session(state) do
          {:ok, state} ->
            send(self(), :poll)
            state = put_in(state.agent.status, :ready)
            Enum.each(state.waiting, &GenServer.reply(&1, ready_reply(state)))
            {:noreply, broadcast_status(%{state | waiting: []})}

          {:error, reason} ->
            fail_boot(state, {:session, reason})
        end

      System.monotonic_time(:millisecond) - state.booted_at > @boot_timeout ->
        fail_boot(state, :agent_boot_timeout)

      true ->
        Process.send_after(self(), :wait_agent, 400)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{agent: %{status: :ready}} = state) do
    if state.busy?, do: answer_forms(state)

    state =
      case Client.messages(conn(state), state.session_id) do
        {:ok, raw} ->
          messages = raw |> Enum.flat_map(&Burrow.Chat.normalize/1) |> Enum.map(&unhint/1)
          pages = raw |> turn(state.prompted_at) |> web_calls() |> Sources.pages()

          state =
            if pages != state.pages,
              do: broadcast_status(%{state | pages: pages}),
              else: state

          state =
            if messages != state.messages do
              GeneralChats.save_messages(chat(state), messages)
              broadcast(%{state | messages: messages}, {:messages, messages})
            else
              state
            end

          if state.busy? and finished?(raw, state.prompted_at),
            do: turn_over(state),
            else: state

        {:error, reason} ->
          Logger.warning("polling general chat #{state.id} failed: #{inspect(reason)}")
          state
      end

    if state.busy?, do: Process.send_after(self(), :poll, @poll_interval)
    {:noreply, state}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({container, {:data, data}}, %{agent: %{container: container}} = state) do
    Logger.debug("general agent #{state.id}: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({container, {:exit_status, code}}, %{agent: %{container: container}} = state) do
    Logger.warning("agent for general chat #{state.id} exited with #{code}")
    {:stop, :normal, put_in(state.agent.container, nil)}
  end

  def handle_info(:idle, %{busy?: true} = state), do: {:noreply, touch(state)}
  def handle_info(:idle, state), do: {:stop, :normal, %{state | stopped: :idle}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    broadcast(state, {:stopped, state.stopped})
    tell_busy(%{state | busy?: false})
    Sandbox.stop(state.agent.name)
  end

  ## The agent

  defp start_agent(state) do
    work = Path.join(state.base, "work")
    config_dir = Path.join(state.base, "opencode-config")
    File.mkdir_p!(work)
    write_agent_config(state, config_dir)
    data_dir = Burrow.OpenCode.data_dir(state.user_id)
    File.mkdir_p!(data_dir)

    bin =
      System.find_executable(Application.get_env(:burrow, :opencode_bin) || "opencode") ||
        raise "opencode not found"

    container =
      Sandbox.start(work, "exec opencode serve --hostname 0.0.0.0 --port 4096",
        label: "burrow.general=#{state.user_id}",
        name: state.agent.name,
        env: %{
          "XDG_CONFIG_HOME" => "/opencode/config",
          "XDG_DATA_HOME" => "/opencode/data",
          "OPENCODE_SERVER_PASSWORD" => state.agent.password
        },
        mounts: [
          {Path.expand(bin) |> resolve_link(), "/usr/local/bin/opencode", :ro},
          {config_dir, "/opencode/config", :ro},
          {data_dir, "/opencode/data", :rw}
        ],
        ports: [{state.agent.port, 4096}]
      )

    %{state | agent: %{state.agent | container: container, status: :starting}}
  end

  # The web is all it may use: no files, no commands, no questions nobody
  # can answer.
  defp write_agent_config(state, config_dir) do
    dir = Path.join(config_dir, "opencode")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "peon.md"), instructions())
    {model, _effort} = model(state)

    deny = ~w(read edit write patch glob grep list bash task todowrite lsp skill question)

    config = %{
      "$schema" => "https://opencode.ai/config.json",
      "model" => model,
      "provider" => Burrow.OpenCode.custom_providers(),
      "autoupdate" => false,
      "share" => "disabled",
      "instructions" => ["/opencode/config/opencode/peon.md"],
      "permission" =>
        Map.new(deny, &{&1, "deny"})
        |> Map.merge(Map.new(@web_tools, &{&1, "allow"}))
        |> Map.merge(%{"external_directory" => "deny", "doom_loop" => "deny"})
    }

    File.write!(Path.join(dir, "opencode.json"), Jason.encode!(config, pretty: true))
  end

  @doc false
  def instructions do
    """
    You are Peon, in Burrow's Chats: a place to ask, search and think. There is no
    project and no code here; you answer, you don't build.

    How to answer:
    1. If the answer depends on facts that change or that you may not know well
       (versions, APIs, prices, dates, news, how a library works today), first search
       the web with websearch and read the best one to three pages with webfetch.
       Answer simple or timeless questions from what you know, without searching.
    2. Answer in plain words and keep it short: a few sentences, or numbered steps for
       a how-to. No headings. Put names of files, commands, functions and packages in
       `backticks`.
    3. Mark each sentence that comes from a page with the page's number in brackets,
       like this.[1] Number the pages in the order you first cite them.
    4. If you cited any page, the very last thing in your answer is this block, one
       line per page, in exactly this format:

    Sources:
    [1] Page title | https://the.page/url | "a short quote from the page that backs the answer"

    If the user wants something built or changed in one of their apps, help them think
    it through, and tell them they can send this chat to a project ("Send to a
    project…") or start a project from it; that project's Peon builds it.
    """
  end

  # The chat's model (provider/model, else its user's) and effort.
  defp model(state) do
    chat = chat(state)
    {(chat && chat.model) || Burrow.OpenCode.model(state.user_id), chat && chat.effort}
  end

  defp chat(state),
    do: GeneralChats.get(state.id) || %GeneralChats.Chat{id: state.id, user_id: state.user_id}

  defp ensure_session(state) do
    chat = chat(state)

    if chat.session_id && Client.session_exists?(conn(state), chat.session_id) do
      {:ok, %{state | session_id: chat.session_id}}
    else
      with {:ok, session_id} <- Client.create_session(conn(state), chat.title) do
        GeneralChats.set(chat, session_id: session_id)
        {:ok, %{state | session_id: session_id}}
      end
    end
  end

  # A turn with the user's message, with the model and thinking level picked
  # last; with web search off, the agent is told not to search.
  defp prompt(state, text, files) do
    chat = chat(state)
    prompted_at = System.system_time(:millisecond)
    {picked, effort} = model(state)
    model = Burrow.OpenCode.usable(picked, Client.model_ids(conn(state)))
    effort = if model == picked, do: effort
    sent = if chat.web == false, do: text <> @no_web, else: text <> @cite_hint

    with :ok <- Client.set_model(conn(state), state.session_id, model, effort),
         {:ok, _} <-
           Client.prompt(conn(state), state.session_id, sent, [], attachments(chat, files)) do
      if chat.started_at == nil or chat.title == "", do: GeneralChats.started(chat, text)
      state = %{state | busy?: true, prompted_at: prompted_at, pages: []}
      send(self(), :poll)
      {:reply, :ok, state |> broadcast_status() |> touch()}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The message's files as data: URIs, named as `GeneralChats.files_dir/1` keeps them.
  defp attachments(chat, files) do
    dir = GeneralChats.files_dir(chat)

    for %{name: name, mime: mime} <- files,
        {:ok, data} <- [File.read(Path.join(dir, name))],
        do: %{uri: "data:#{mime};base64,#{Base.encode64(data)}", name: name}
  end

  # The answer is in: the chat keeps the pages the agent found and how many
  # sources the answer cites.
  defp turn_over(state) do
    chat = chat(state)

    case state.messages |> Enum.filter(&(&1.role == :user)) |> List.last() do
      %{id: turn} -> GeneralChats.save_pages(chat, turn, state.pages)
      nil -> :ok
    end

    sources =
      case state.messages |> Enum.filter(&(&1.role == :assistant)) |> List.last() do
        %{text: text} ->
          case Sources.split(text) do
            {_answer, []} -> length(Sources.fallback(state.pages))
            {_answer, cited} -> length(cited)
          end

        nil ->
          0
      end

    GeneralChats.answered(chat, sources)
    broadcast_status(%{state | busy?: false})
  end

  # opencode asks which web search to use the first time the user's agents
  # search, and nobody is there to answer: Exa, which needs no key. The
  # choice stays with the user's opencode data, for their other agents too.
  defp answer_forms(state) do
    with {:ok, forms} <- Client.forms(conn(state), state.session_id) do
      for %{"id" => id, "metadata" => %{"kind" => "websearch.provider"}, "fields" => fields} <-
            forms do
        answer =
          case Enum.map(fields, & &1["key"]) do
            ["provider" | _] -> %{provider: "exa"}
            _ -> %{choice: "choose"}
          end

        Client.reply_form(conn(state), state.session_id, id, answer)
      end
    end
  end

  defp finished?(raw, prompted_at),
    do: Enum.any?(raw, &(&1["type"] == "idle" and get_in(&1, ["time", "created"]) >= prompted_at))

  # The raw messages since the user's message at `prompted_at`.
  defp turn(raw, prompted_at),
    do: Enum.filter(raw, &((get_in(&1, ["time", "created"]) || 0) >= prompted_at))

  # The agent's web tool calls: `[%{tool, input, output}]`.
  defp web_calls(raw) do
    for %{"type" => "assistant", "content" => content} <- raw,
        is_list(content),
        %{"type" => type} = part <- content,
        type in ["tool", "tool-call", "tool_call"],
        tool = part["name"] || part["tool"] || get_in(part, ["call", "name"]),
        tool in @web_tools,
        do: %{
          tool: tool,
          input: part["input"] || part["arguments"] || get_in(part, ["state", "input"]) || %{},
          output: tool_output(part)
        }
  end

  defp tool_output(part) do
    case get_in(part, ["state", "content"]) || get_in(part, ["state", "output"]) || part["output"] do
      text when is_binary(text) -> text
      [_ | _] = content -> Enum.map_join(content, "\n", &(&1["text"] || ""))
      _ -> nil
    end
  end

  defp unhint(%{role: :user, text: text} = m),
    do: %{
      m
      | text: text |> String.replace_suffix(@no_web, "") |> String.replace_suffix(@cite_hint, "")
    }

  defp unhint(m), do: m

  defp fail_boot(state, reason) do
    Logger.error("general chat #{state.id} could not start its agent: #{inspect(reason)}")
    state = put_in(state.agent.status, {:error, reason})
    Enum.each(state.waiting, &GenServer.reply(&1, ready_reply(state)))
    {:stop, :normal, %{state | waiting: []}}
  end

  ## Helpers

  defp conn(state),
    do: %{base_url: "http://127.0.0.1:#{state.agent.port}", password: state.agent.password}

  defp ready_reply(%{agent: %{status: :ready}} = state), do: {:ok, info_map(state)}
  defp ready_reply(%{agent: %{status: {:error, reason}}}), do: {:error, reason}

  defp info_map(state),
    do: %{
      agent_status: state.agent.status,
      busy?: state.busy?,
      messages: state.messages,
      pages: state.pages
    }

  defp broadcast(state, message) do
    GeneralChats.broadcast_chat(state.id, message)
    state
  end

  defp broadcast_status(state),
    do: state |> broadcast({:status, Map.delete(info_map(state), :messages)}) |> tell_busy()

  defp tell_busy(%{busy?: busy?, told_busy?: busy?} = state), do: state

  defp tell_busy(state) do
    busy? = state.busy?
    Registry.update_value(@registry, {{:general, state.user_id}, state.id}, &%{&1 | busy?: busy?})
    GeneralChats.broadcast(state.user_id, {:general_busy, state.id, busy?})
    %{state | told_busy?: busy?}
  end

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_timeout)}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp resolve_link(path) do
    case File.read_link(path) do
      {:ok, target} -> target |> Path.expand(Path.dirname(path)) |> resolve_link()
      {:error, _} -> path
    end
  end
end
