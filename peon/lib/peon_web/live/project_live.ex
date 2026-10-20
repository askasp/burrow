defmodule PeonWeb.ProjectLive do
  @moduledoc """
  The workspace, laid out as the Peon UI kit's "Peon workspace" board (the
  Burrow design): the project and its chats on the left, the chat with its
  current changeset in the middle, and the live preview on the right, which
  switches between the chat's dev preview, staging and prod. Main's tests,
  staging and prod sit under the chats; incidents and deploys open in a panel.
  """

  use PeonWeb, :live_view

  alias Peon.{Chat, Chats, Checks, Code, Env, Incidents, Project, Secrets, Ship, Store, Verifier}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Chats.subscribe()
      Store.subscribe()
      Checks.subscribe()
      Env.subscribe()
      Incidents.subscribe()
      Secrets.subscribe()
    end

    {:ok,
     socket
     |> assign(project: Project.get(), chat: nil, info: nil, preview_env: "dev")
     |> assign(burrow_url: Application.get_env(:peon, :burrow_url))
     # The project rail: the user's projects in Burrow; the chats column can fold away
     |> assign(rail: [], left_open: true)
     |> load_rail()
     |> assign(repo?: Peon.Source.repo?())
     |> load_chats()
     |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
     # Why the open chat stopped (Peon.Chat's {:stopped, reason}), while it is
     |> assign(stopped: nil)
     |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
     |> assign(changeset: nil, main_id: nil, form: to_form(%{"text" => ""}))
     # The "/" menu: the chat's commands and skills, and those matching the box
     |> assign(slash_items: [], slash: [])
     |> assign(landed?: false, held: nil, env_names: Ship.env_names(), show_ship: false)
     |> assign(secrets: Secrets.list(), show_secrets: false, secrets_key: 0)
     # Phones: one pane at a time, chats in a drawer
     |> assign(pane: "chat", drawer: false)
     |> assign(envs: Map.new(Ship.env_names(), &{&1, Env.info(&1)}))
     |> load_ship()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Chats.get(id) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      chat ->
        if old = socket.assigns.chat,
          do: Phoenix.PubSub.unsubscribe(Peon.PubSub, "chat:#{old.id}")

        if connected?(socket), do: Chat.subscribe(id)

        socket =
          socket
          |> assign(chat: chat, info: nil, start_error: nil, show_logs: false, drawer: false)
          |> assign(slash_items: [], slash: [], stopped: nil)
          |> load_changeset()

        if connected?(socket),
          do: {:noreply, start_chat(socket)},
          else: {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    if old = socket.assigns.chat, do: Phoenix.PubSub.unsubscribe(Peon.PubSub, "chat:#{old.id}")

    {:noreply,
     assign(socket, chat: nil, info: nil, changeset: nil, starting: false, drawer: false)}
  end

  defp start_chat(socket) do
    id = socket.assigns.chat.id

    socket
    |> assign(starting: true, stopped: nil, start_error: nil)
    |> start_async(:chat, fn -> Chat.ensure_started(id) end)
  end

  @impl true
  def handle_async(:chat, {:ok, {:ok, info}}, socket) do
    socket = assign(socket, info: info, starting: false)

    case socket.assigns.pending do
      nil -> {:noreply, socket}
      text -> {:noreply, socket |> assign(pending: nil) |> prompt(text)}
    end
  end

  def handle_async(:chat, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, starting: false, start_error: start_error(reason))}
  end

  def handle_async(:rail, {:ok, rail}, socket), do: {:noreply, assign(socket, rail: rail)}
  def handle_async(:rail, {:exit, _}, socket), do: {:noreply, socket}

  def handle_async(:chat, {:exit, reason}, socket) do
    {:noreply, assign(socket, starting: false, start_error: start_error(reason))}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.chat && socket.assigns.stopped ->
        {:noreply,
         socket |> assign(pending: text, form: to_form(%{"text" => ""})) |> start_chat()}

      socket.assigns.chat && socket.assigns.info ->
        {:noreply, socket |> assign(form: to_form(%{"text" => ""}), slash: []) |> prompt(text)}

      socket.assigns.chat ->
        {:noreply, assign(socket, pending: text)}

      true ->
        chat = Chats.create(text, socket.assigns.user)
        {:noreply, socket |> assign(pending: text) |> push_patch(to: ~p"/c/#{chat.id}")}
    end
  end

  def handle_event("typing", %{"text" => text}, socket), do: {:noreply, slash_menu(socket, text)}

  def handle_event("wake", _params, socket), do: {:noreply, start_chat(socket)}

  def handle_event("toggle_left", _params, socket),
    do: {:noreply, update(socket, :left_open, &(!&1))}

  def handle_event("keep_running", %{"hours" => hours}, socket) do
    chat = socket.assigns.chat

    case Integer.parse(hours) do
      {hours, ""} ->
        until = Chats.keep_running(chat.id, hours)
        socket = assign(socket, chat: %{chat | keep_until: until})
        {:noreply, if(socket.assigns.stopped, do: start_chat(socket), else: socket)}

      _ ->
        Chats.keep_running(chat.id, nil)
        {:noreply, assign(socket, chat: %{chat | keep_until: nil})}
    end
  end

  # Stopping a repo preview can take minutes, so deleting runs on its own.
  def handle_event("delete_chat", _params, socket) do
    id = socket.assigns.chat.id
    Task.Supervisor.start_child(Peon.TaskSupervisor, fn -> Chat.delete(id) end)
    {:noreply, socket |> info("Chat deleted.") |> push_patch(to: ~p"/")}
  end

  def handle_event("pick_slash", %{"name" => name}, socket) do
    {:noreply, socket |> assign(slash: []) |> push_event("slash:pick", %{text: "/#{name} "})}
  end

  def handle_event("interrupt", _params, socket) do
    Chat.interrupt(socket.assigns.chat.id)
    {:noreply, socket}
  end

  def handle_event("land", %{"id" => id}, socket) do
    case Ship.merge(String.to_integer(id), socket.assigns.user) do
      {:ok, cs} ->
        text =
          if Ship.live_only?(),
            do: "Changeset #{cs.id} is on main and going live.",
            else: "Changeset #{cs.id} is now on main."

        {:noreply, socket |> info(text) |> load_changeset()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not land: #{inspect(reason)}")}
    end
  end

  def handle_event("revert", %{"id" => id}, socket) do
    case Ship.revert(String.to_integer(id), socket.assigns.user) do
      {:ok, cs} ->
        {:noreply, info(socket, "Revert submitted as ##{cs.id}; it lands once checked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revert: #{inspect(reason)}")}
    end
  end

  def handle_event("promote", %{"id" => id}, socket) do
    prod = Code.ref("prod")
    user = socket.assigns.user
    version = if prod, do: prod.version, else: 0

    case Store.move_ref("prod", String.to_integer(id), version, user, approved_by: user) do
      {:ok, _} ->
        {:noreply, info(socket, "Deploying ##{id} to prod.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not promote: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_auto_promote", _params, socket) do
    on? = Project.settings()["auto_promote"] != true
    Project.put_settings(%{"auto_promote" => on?, "auto_promote_by" => socket.assigns.user})
    {:noreply, load_ship(socket)}
  end

  def handle_event("restart_env", %{"env" => env}, socket) do
    Env.restart(env)
    {:noreply, socket}
  end

  def handle_event("fix_incident", %{"id" => id}, socket) do
    incident = Incidents.fix(Incidents.get(String.to_integer(id)), socket.assigns.user)
    {:noreply, push_patch(socket, to: ~p"/c/#{incident.chat_id}")}
  end

  def handle_event("resolve_incident", %{"id" => id}, socket) do
    Incidents.resolve(Incidents.get(String.to_integer(id)))
    {:noreply, socket}
  end

  def handle_event("toggle_ship", _params, socket),
    do:
      {:noreply,
       socket |> update(:show_ship, &(!&1)) |> assign(show_secrets: false) |> load_ship()}

  def handle_event("toggle_secrets", _params, socket),
    do: {:noreply, socket |> update(:show_secrets, &(!&1)) |> assign(show_ship: false)}

  def handle_event("set_secret", %{"name" => name, "value" => value}, socket) do
    name = name |> String.trim() |> String.upcase()

    case Secrets.put(name, String.trim(value), socket.assigns.user) do
      :ok ->
        {:noreply,
         socket
         |> update(:secrets_key, &(&1 + 1))
         |> info("#{name} is set. The preview, staging and prod restart to pick it up.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_secret", %{"name" => name}, socket) do
    Secrets.delete(name)
    {:noreply, info(socket, "#{name} is removed.")}
  end

  def handle_event("restart_preview", _params, socket) do
    Chat.restart_preview(socket.assigns.chat.id)
    {:noreply, socket}
  end

  def handle_event("reload_preview", _params, socket),
    do: {:noreply, update(socket, :frame_key, &(&1 + 1))}

  def handle_event("drawer", _params, socket),
    do: {:noreply, update(socket, :drawer, &(!&1))}

  def handle_event("pane", %{"pane" => pane}, socket) when pane in ["chat", "preview"],
    do: {:noreply, assign(socket, pane: pane)}

  def handle_event("preview_env", %{"env" => env}, socket) when env in ["dev", "staging", "prod"],
    do:
      {:noreply,
       socket |> assign(preview_env: env) |> update(:frame_key, &(&1 + 1)) |> load_logs()}

  def handle_event("toggle_logs", _params, socket),
    do: {:noreply, socket |> update(:show_logs, &(!&1)) |> load_logs()}

  def handle_event("toggle_attach", _params, socket),
    do: {:noreply, update(socket, :show_attach, &(!&1))}

  @impl true
  def handle_info({:messages, messages}, socket),
    do: {:noreply, update_info(socket, messages: messages)}

  def handle_info({:status, status}, socket) do
    was = socket.assigns.info && socket.assigns.info.preview_status
    socket = update_info(socket, status)

    # Reload the preview once it is up, so it gets its freshly built assets.
    if status.preview_status == :running and was != :running,
      do: {:noreply, update(socket, :frame_key, &(&1 + 1))},
      else: {:noreply, socket}
  end

  def handle_info({:conflicts, paths}, socket),
    do: {:noreply, update_info(socket, conflicts: paths)}

  def handle_info({:chat_created, _}, socket), do: {:noreply, load_chats(socket)}

  def handle_info({:chat_deleted, id}, socket) do
    socket = load_chats(socket)

    if socket.assigns.chat && socket.assigns.chat.id == id,
      do: {:noreply, push_patch(socket, to: ~p"/")},
      else: {:noreply, socket}
  end

  # The open chat stopped; the thread stays, the next message starts it again.
  def handle_info({:stopped, reason}, %{assigns: %{info: info}} = socket)
      when info != nil and reason != :deleted do
    {:noreply,
     socket
     |> update_info(preview_status: :stopped, busy?: false)
     |> assign(stopped: reason, slash_items: [], slash: [])}
  end

  def handle_info({:stopped, _reason}, socket), do: {:noreply, socket}

  def handle_info({:env, name, info}, socket) do
    socket = update(socket, :envs, &Map.put(&1, name, info))
    # Stats arrive every few seconds; only reload the lists when something moved.
    if info.deploy || socket.assigns.show_ship,
      do: {:noreply, load_ship(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:incident, _}, socket), do: {:noreply, load_ship(socket)}

  def handle_info({:secrets, secrets}, socket), do: {:noreply, assign(socket, secrets: secrets)}

  def handle_info({:check_step, _id, step, status}, socket),
    do: {:noreply, socket |> assign(step: {step, status}) |> load_changeset()}

  def handle_info(:clear_info, socket), do: {:noreply, clear_flash(socket, :info)}

  def handle_info(_msg, socket), do: {:noreply, socket |> load_changeset() |> load_ship()}

  # Info flashes clear themselves so they don't cover the ship bar; errors stay.
  defp info(socket, text) do
    Process.send_after(self(), :clear_info, 4_000)
    put_flash(socket, :info, text)
  end

  # While the box holds just "/name", the commands and skills it matches,
  # names starting with it first. A bare "/" reloads them: the agent may have
  # added one to the workspace.
  defp slash_menu(%{assigns: %{info: nil}} = socket, _text), do: assign(socket, slash: [])

  defp slash_menu(socket, text) do
    case Regex.run(~r{\A/(\S*)\z}, text) do
      [_, typed] ->
        socket = if typed == "", do: load_slash(socket), else: socket

        matches =
          socket.assigns.slash_items
          |> Enum.filter(&String.contains?(&1.name, typed))
          |> Enum.sort_by(&(not String.starts_with?(&1.name, typed)))
          |> Enum.take(8)

        assign(socket, slash: matches)

      nil ->
        assign(socket, slash: [])
    end
  end

  defp load_slash(socket) do
    case Chat.slash_commands(socket.assigns.chat.id) do
      {:ok, items} -> assign(socket, slash_items: items)
      _ -> socket
    end
  end

  defp prompt(socket, text) do
    case Chat.send_message(socket.assigns.chat.id, text) do
      :ok -> update_info(socket, busy?: true)
      {:error, reason} -> put_flash(socket, :error, "Could not send: #{inspect(reason)}")
    end
  end

  defp update_info(%{assigns: %{info: nil}} = socket, _changes), do: socket

  defp update_info(socket, changes),
    do: assign(socket, info: Map.merge(socket.assigns.info, Map.new(changes)))

  # The dev preview's log comes from the chat, staging's and prod's from their env.
  defp load_logs(%{assigns: %{show_logs: false}} = socket), do: socket

  defp load_logs(%{assigns: %{preview_env: "dev", chat: %{id: id}}} = socket) do
    case Chat.logs(id) do
      {:ok, logs} -> assign(socket, logs: logs)
      _ -> socket
    end
  end

  defp load_logs(%{assigns: %{preview_env: env}} = socket) when env in ["staging", "prod"],
    do: assign(socket, logs: Env.logs(env))

  defp load_logs(socket), do: socket

  # The chats with their latest changeset: "#12" open, "✓ #9" on main.
  defp load_chats(socket) do
    main = Code.ref("main")

    chats =
      for chat <- Chats.list() do
        tag =
          case Chats.latest_changeset(chat.id) do
            nil ->
              nil

            cs ->
              if(main && Code.ancestor?(cs.id, main.changeset_id),
                do: "✓ ##{cs.id}",
                else: "##{cs.id}"
              )
          end

        Map.put(chat, :tag, tag)
      end

    assign(socket, chats: chats)
  end

  defp load_changeset(%{assigns: %{chat: nil}} = socket), do: socket

  defp load_changeset(socket) do
    main_id = with(%{changeset_id: id} <- Code.ref("main"), do: id)
    changeset = Chats.latest_changeset(socket.assigns.chat.id)

    assign(socket,
      changeset: changeset,
      main_id: main_id,
      landed?: changeset != nil and Code.ancestor?(changeset.id, main_id),
      held: if(changeset && changeset.status == "passed", do: Ship.review_reasons(changeset))
    )
  end

  defp load_ship(socket) do
    main =
      case Code.resolve("main") do
        {:ok, cs} -> cs
        _ -> nil
      end

    socket =
      assign(socket,
        main: main,
        incidents: Incidents.list(),
        culprit: Verifier.culprit(),
        auto_promote: Project.settings()["auto_promote"] == true
      )

    if socket.assigns.show_ship,
      do: assign(socket, deploys: Map.new(socket.assigns.env_names, &{&1, Env.deploys(&1, 5)})),
      else: assign(socket, deploys: %{})
  end

  defp start_error({:session, _}),
    do: "The agent started but could not open a session. Is an AI provider connected in Burrow?"

  defp start_error(:no_free_preview_port),
    do:
      "Every preview slot is in use by another chat. Close one, or wait for an idle chat to stop."

  defp start_error("git " <> _ = output),
    do: "Could not check out the repo: #{output}"

  defp start_error(reason), do: "The agent could not start: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        preview: preview(assigns),
        promote: promote_target(assigns),
        open_incidents: Enum.count(assigns.incidents, &(&1.status != "resolved"))
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={["ws-root", @drawer && "drawer"]} data-pane={@pane}>
      <header class="ws-mbar">
        <button
          type="button"
          phx-click="drawer"
          class="ws-mbar-menu"
          aria-label="Chats and project"
          aria-expanded={to_string(@drawer)}
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
        <span class="ws-mbar-title truncate">{(@chat && @chat.title) || "New chat"}</span>
        <div class="seg" role="group" aria-label="View">
          <button
            :for={{pane, label} <- [{"chat", "Chat"}, {"preview", "Preview"}]}
            type="button"
            phx-click="pane"
            phx-value-pane={pane}
            aria-pressed={to_string(@pane == pane)}
          >
            {label}
          </button>
        </div>
      </header>
      <div :if={@drawer} class="ws-scrim" phx-click="drawer" aria-hidden="true"></div>
      <nav class="ws-rail" data-kb-zoom-hide aria-label="Projects">
        <a href={@burrow_url || ~p"/"} class="ws-rail-home" title="All projects">
          <Layouts.mark size={26} />
        </a>
        <div class="ws-rail-list">
          <%= for p <- @rail do %>
            <span
              :if={p.current}
              class="ws-tile current"
              title={p.name}
              aria-current="page"
            >
              {tile_initials(p.name)}<i class={["dot", rail_tone(p.status)]}></i>
            </span>
            <a :if={!p.current} href={p.url} class="ws-tile" title={"#{p.name} · #{p.status}"}>
              {tile_initials(p.name)}<i class={["dot", rail_tone(p.status)]}></i>
            </a>
          <% end %>
        </div>
        <button
          type="button"
          phx-click="toggle_left"
          class="ws-tile ws-rail-fold"
          data-kb-key="b"
          data-kb-label={if @left_open, do: "Hide chats", else: "Show chats"}
          data-kb-group="Chats"
          aria-pressed={to_string(!@left_open)}
          title={if @left_open, do: "Hide chats", else: "Show chats"}
        >
          <.icon
            name={if @left_open, do: "hero-chevron-double-left", else: "hero-chevron-double-right"}
            class="size-4"
          />
        </button>
      </nav>
      <aside
        class={["ws-left", !@left_open && "folded"]}
        data-kb-zoom-hide
        aria-label="Project and chats"
      >
        <div class="ws-left-top">
          <a href={@burrow_url || ~p"/"} class="ws-brand" aria-label="Peon, back to projects">
            <Layouts.mark size={26} /> <span>peon</span>
          </a>
          <div class="ws-project">
            <a :if={@burrow_url} href={@burrow_url} class="ws-back">
              <.icon name="hero-chevron-left" class="size-3.5" /> All projects
            </a>
            <div class="flex items-center gap-2">
              <div class="flex flex-col min-w-0 mr-auto">
                <span class="ws-project-name">{@project && @project.name}</span>
                <span class="mono ws-project-slug">{@project && @project.slug}</span>
              </div>
              <span :if={@info} class={["st", st_tone(@info.preview_status)]}>
                <span class="dot"></span>{preview_word(@info.preview_status)}
              </span>
            </div>
          </div>
          <.link
            patch={~p"/"}
            data-kb-key="c"
            data-kb-label="New chat"
            data-kb-group="Chats"
            data-kb-focus="#chat-input"
            class="btn btn-secondary btn-sm w-full"
          >
            <.icon name="hero-plus" class="size-4" /> New chat
          </.link>
        </div>

        <nav class="ws-convos" aria-label="Chats">
          <div class="eyebrow px-1.5 pt-2 pb-1.5">Chats</div>
          <.link
            :for={c <- @chats}
            patch={~p"/c/#{c.id}"}
            data-kb="item"
            data-kb-current={if(@chat && @chat.id == c.id, do: "1")}
            aria-current={if(@chat && @chat.id == c.id, do: "page")}
            class={["convo", @chat && @chat.id == c.id && "active"]}
          >
            <span class="truncate">{c.title}</span>
            <span :if={c.tag} class="meta mono">{c.tag}</span>
          </.link>
        </nav>

        <.ship_status
          :if={not @repo?}
          main={@main}
          culprit={@culprit}
          envs={@envs}
          env_names={@env_names}
          auto_promote={@auto_promote}
          promote={@promote}
          open_incidents={@open_incidents}
        />

        <div class="ws-secrets-link">
          <button
            phx-click="toggle_secrets"
            data-kb-key="k"
            data-kb-label="Secrets"
            data-kb-group="Ship"
            class={["xlink", asked(@secrets) != [] && "text-[var(--warn)]"]}
          >
            {secrets_text(@secrets)}
          </button>
        </div>

        <div class="ws-account">
          <span class="ws-avatar" aria-hidden="true">{initials(@user)}</span>
          <span class="truncate">{@user}</span>
        </div>
      </aside>

      <main class="ws-chat" data-kb-zoom-hide>
        <header class="ws-chat-head">
          <h1 class="truncate">{(@chat && @chat.title) || "New chat"}</h1>
          <span :if={@changeset} class="mono muted text-xs shrink-0">
            {if(@landed?, do: "##{@changeset.id} on main", else: "##{@changeset.id}")}
          </span>
          <form :if={@chat} id="keep-running-form" phx-change="keep_running" class="ml-auto shrink-0">
            <label class="sr-only" for="keep-running">Keep running</label>
            <select
              id="keep-running"
              name="hours"
              class="field keep"
              title="How long the agent and preview stay up without use, e.g. while others test the preview"
            >
              <option :if={Chats.kept_running?(@chat)} value="kept" selected>
                Running until {Calendar.strftime(@chat.keep_until, "%b %-d, %H:%M UTC")}
              </option>
              <option value="">Stops after 30 min idle</option>
              <option value="4">Keep running 4 hours</option>
              <option value="24">Keep running 1 day</option>
              <option value="168">Keep running 7 days</option>
            </select>
          </form>
          <button
            :if={@chat}
            type="button"
            phx-click="delete_chat"
            data-confirm={
              if @repo?,
                do:
                  "Delete this chat? Its agent, preview and checkout go; a pull request it opened stays open.",
                else: "Delete this chat? Its agent, preview and workspace go; landed changesets stay."
            }
            class="icon-btn sm shrink-0"
            aria-label="Delete chat"
            title="Delete chat"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </header>

        <div class="ws-scroll" id="messages" phx-hook=".ScrollBottom">
          <div class="ws-thread">
            <div :if={@chat == nil and @pending == nil} class="ws-hello">
              <Layouts.mark size={56} />
              <h2>Something need doing?</h2>
            </div>
            <div :if={@starting} class="ws-working" role="status">
              <.icon name="hero-arrow-path" class="size-4 spin" /> Starting the agent and preview…
            </div>
            <div :if={@start_error} class="say-error">{@start_error}</div>
            <%= for block <- blocks((@info && @info.messages) || []) do %>
              <.block block={block} />
            <% end %>
            <div :if={@pending} class="bubble-user opacity-60">{@pending}</div>
            <div :if={@info && @info.busy?} class="ws-working" role="status">
              <Layouts.mark size={28} />
              <span class="swing text-[var(--rust)]"><.icon name="hero-wrench" class="size-4" /></span>
              <span class="flex flex-col min-w-0">
                <span class="font-medium">Work, work.</span>
                <span class="text-[13px] text-[var(--text-2)] truncate">
                  {doing(@info.messages)}
                </span>
              </span>
              <button
                phx-click="interrupt"
                data-kb-key="x"
                data-kb-label="Stop the agent"
                data-kb-group="Agent & preview"
                data-kb-esc
                class="btn btn-ghost btn-sm"
              >
                Stop
              </button>
            </div>
          </div>
        </div>

        <div class="ws-bottom">
          <div :if={@culprit} class="notice err">
            <span>Main's tests fail since #{@culprit.id}: {@culprit.intent}</span>
            <button
              phx-click="revert"
              phx-value-id={@culprit.id}
              data-kb="row"
              class="btn btn-danger btn-sm ml-auto"
            >
              revert
            </button>
          </div>
          <div :if={@info && @info.conflicts != []} class="notice warn">
            Main changed files this chat also changed (the chat's version is kept): {Enum.join(
              @info.conflicts,
              ", "
            )}
          </div>
          <.connect_card
            :if={@chat && asked(@secrets, @chat.id) != []}
            secrets={asked(@secrets, @chat.id)}
            key={@secrets_key}
          />
          <.changeset_card
            :if={@changeset}
            changeset={@changeset}
            landed?={@landed?}
            held={@held}
            step={@step}
            envs={@envs}
          />
          <.form for={@form} id="composer" phx-submit="send" phx-change="typing" class="composer">
            <div
              :if={@slash != []}
              id="slash-menu"
              class="slash"
              role="listbox"
              aria-label="Commands and skills"
            >
              <button
                :for={{item, i} <- Enum.with_index(@slash)}
                type="button"
                role="option"
                aria-selected={to_string(i == 0)}
                phx-click="pick_slash"
                phx-value-name={item.name}
                class="slash-item"
              >
                <span class="mono shrink-0">/{item.name}</span>
                <span class="tag shrink-0">{item.kind}</span>
                <span class="muted truncate">{item.description}</span>
              </button>
            </div>
            <label class="sr-only" for="chat-input">Message Peon</label>
            <textarea
              name="text"
              rows="2"
              id="chat-input"
              data-kb="search"
              data-kb-label="Chat box"
              phx-hook=".SubmitOnEnter"
              placeholder={
                if @chat, do: "Describe a change… (/ for commands)", else: "Describe your app…"
              }
            >{@form[:text].value}</textarea>
            <div class="cbar">
              <button :if={@info} type="button" phx-click="toggle_attach" data-kb="row" class="xlink">
                Open in opencode
              </button>
              <button class="btn btn-primary ws-send" aria-label="Send">
                <.icon name="hero-arrow-up" class="size-4" />
              </button>
            </div>
            <pre :if={@info && @show_attach} class="out mono">{@info.attach}</pre>
          </.form>
        </div>
      </main>

      <section class="ws-prev" aria-label="Live preview">
        <div class="ws-prev-bar">
          <div class="seg" role="group" aria-label="Environment">
            <button
              :for={env <- ["dev" | @env_names]}
              type="button"
              phx-click="preview_env"
              phx-value-env={env}
              aria-pressed={to_string(@preview_env == env)}
            >
              {env}
            </button>
          </div>
          <span :if={@preview.status} class={["st", st_tone(@preview.status)]}>
            <span class="dot"></span>{preview_word(@preview.status)}
          </span>
          <div class="ws-url mono">
            <.icon name="hero-lock-closed" class="size-3.5 shrink-0 muted" />
            <span class="truncate">{@preview.url || "no preview yet"}</span>
          </div>
          <span :if={@preview.ref} class="tag mono" title="Version shown in the preview">{@preview.ref}</span>
          <a
            :for={{name, url} <- @preview[:links] || []}
            href={url}
            target="_blank"
            rel="noopener"
            class="tag mono"
            title={"Open #{name} in a new tab"}
          >
            {name} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </a>
          <a
            :if={@preview[:pr]}
            href={@preview.pr}
            target="_blank"
            rel="noopener"
            class="tag mono"
            title="The chat's pull request"
          >
            PR {pr_number(@preview.pr)} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </a>
          <button
            :if={@preview.url}
            type="button"
            phx-click="reload_preview"
            data-kb-key="r"
            data-kb-label="Reload preview"
            data-kb-group="Agent & preview"
            class="icon-btn"
            aria-label="Reload preview"
          >
            <.icon name="hero-arrow-path" class="size-[18px]" />
          </button>
          <a
            :if={@preview.url}
            href={@preview.url}
            target="_blank"
            rel="noopener"
            data-kb="row"
            class="icon-btn"
            aria-label={"Open #{@preview_env} in a new tab"}
            title={"Open #{@preview_env} in a new tab"}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-[17px]" />
          </a>
          <button
            :if={@preview_env == "dev" and @info}
            type="button"
            phx-click="restart_preview"
            data-kb-key="R"
            data-kb-label="Restart preview"
            data-kb-group="Agent & preview"
            class="btn btn-ghost btn-sm"
          >
            Restart
          </button>
          <button
            :if={@preview.url}
            type="button"
            phx-click="toggle_logs"
            data-kb-key="v"
            data-kb-label="Preview logs"
            data-kb-group="Agent & preview"
            aria-pressed={to_string(@show_logs)}
            class="btn btn-secondary btn-sm"
          >
            <.icon name="hero-command-line" class="size-4" /> Logs
          </button>
        </div>

        <div class="ws-prev-body">
          <iframe
            :if={@preview.live?}
            id={"preview-#{@preview_env}-#{@frame_key}"}
            src={@preview.url}
            class="ws-frame"
          />
          <div :if={!@preview.live?} class="ws-prev-empty" role="status">
            <.icon
              :if={@preview.status in [:starting, :booting, :loading, :watching]}
              name="hero-arrow-path"
              class="size-8 spin text-[var(--accent-text)]"
            />
            <div class="ws-prev-title">{@preview.message}</div>
            <button
              :if={@preview[:wake]}
              type="button"
              phx-click="wake"
              data-kb="row"
              class="btn btn-primary"
            >
              Start again
            </button>
            <a
              :if={@preview[:open] && @preview.url}
              href={@preview.url}
              target="_blank"
              rel="noopener"
              data-kb="row"
              class="btn btn-primary"
            >
              Open {@preview_env} in a new tab
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </a>
          </div>
          <section :if={@show_logs} class="ws-logs" aria-label="Logs">
            <div class="ws-logs-head">
              <.icon name="hero-command-line" class="size-4 muted" />
              <span class="font-semibold text-[13px]">Logs</span>
              <span class="mono muted text-xs">{@project && @project.slug} · {@preview_env}</span>
              <button
                type="button"
                phx-click="toggle_logs"
                class="icon-btn sm ml-auto"
                aria-label="Hide logs"
              >
                <.icon name="hero-chevron-down" class="size-4" />
              </button>
            </div>
            <pre class="ws-logs-body mono">{@logs}</pre>
          </section>
        </div>
      </section>

      <.ship_panel
        :if={@show_ship}
        auto_promote={@auto_promote}
        envs={@envs}
        env_names={@env_names}
        incidents={@incidents}
        deploys={@deploys}
      />

      <.secrets_panel :if={@show_secrets} secrets={@secrets} key={@secrets_key} />
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
      export default {
        mounted() { this.el.scrollTop = this.el.scrollHeight },
        updated() { this.el.scrollTop = this.el.scrollHeight }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
      export default {
        mounted() {
          this.handleEvent("slash:pick", ({text}) => {
            this.el.value = text
            this.el.focus()
            this.el.setSelectionRange(text.length, text.length)
          })
          this.el.addEventListener("keydown", e => {
            // The "/" menu: arrows move, Tab or Enter picks
            const items = [...document.querySelectorAll("#slash-menu [role=option]")]
            const at = items.findIndex(b => b.getAttribute("aria-selected") === "true")
            if (items.length && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
              e.preventDefault()
              const next = (at + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length
              items.forEach((b, i) => b.setAttribute("aria-selected", String(i === next)))
              return
            }
            if (items.length && (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey))) {
              e.preventDefault()
              items[Math.max(at, 0)].click()
              return
            }
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              this.el.form.requestSubmit()
              this.el.value = ""
            }
          })
        }
      }
    </script>
    """
  end

  defp pr_number(url), do: "#" <> (url |> String.split("/") |> List.last())

  defp load_rail(socket) do
    user = socket.assigns.user

    if connected?(socket),
      do: start_async(socket, :rail, fn -> Peon.Burrow.projects(user) end),
      else: socket
  end

  # A project's tile in the rail: "Sauna Booking" -> "SB", "watchtower" -> "Wa".
  defp tile_initials(name) do
    case String.split(name || "?", ~r/[\s_-]+/, trim: true) do
      [a, b | _] -> String.upcase(String.first(a) <> String.first(b))
      [one] -> String.capitalize(String.slice(one, 0, 2))
      [] -> "?"
    end
  end

  defp rail_tone("running"), do: "ok"
  defp rail_tone("starting"), do: "warn"
  defp rail_tone("exited"), do: "err"
  defp rail_tone(_), do: "idle"

  # What the preview pane shows: the chat's dev preview, or staging or prod.
  defp preview(%{preview_env: "dev", info: nil, chat: chat, starting: starting}) do
    message =
      if chat || starting,
        do: "Starting the preview…",
        else: "The preview starts with your first chat."

    %{url: nil, status: if(chat, do: :starting), ref: nil, live?: false, message: message}
  end

  defp preview(%{preview_env: "dev", info: info, changeset: cs, stopped: stopped}) do
    %{
      links: info[:preview_links] || [],
      pr: info[:pr_url],
      url: info.preview_url,
      status: info.preview_status,
      ref: cs && "##{cs.id}",
      live?: info.preview_status == :running,
      message:
        if(stopped, do: stopped_message(stopped), else: preview_message(info.preview_status)),
      wake: stopped != nil
    }
  end

  defp preview(%{preview_env: env, envs: envs}) do
    case envs[env] do
      # Real environments keep frame-ancestors 'self' (clickjacking protection),
      # so they open in their own tab instead of the frame.
      %{deployed: id} = info when id != nil ->
        %{
          url: info.url,
          status: info.status,
          ref: "##{id}",
          live?: false,
          message: env_message(env, info),
          open: true
        }

      info ->
        %{
          url: info && info.url,
          status: info && info.status,
          ref: nil,
          live?: false,
          message: "Nothing is deployed to #{env} yet."
        }
    end
  end

  defp promote_target(%{auto_promote: true}), do: nil

  defp promote_target(%{envs: envs}) do
    with %{good: good} when good != nil <- envs["staging"],
         %{} = prod <- envs["prod"],
         true <- good != prod.deployed do
      good
    else
      _ -> nil
    end
  end

  # Consecutive agent output is one Peon turn under the user's message.
  # A Peon turn that answers the user (not one of Peon's own "[Peon] ..." notes)
  # opens with the peon's "Zug zug.", like taking an order in Warcraft III.
  defp blocks(messages) do
    messages
    |> Enum.chunk_by(&(&1.role == :user))
    |> Enum.flat_map_reduce(false, fn
      [%{role: :user} | _] = users, _ack? ->
        {Enum.map(users, &{:user, &1}), not String.starts_with?(List.last(users).text, "[Peon]")}

      agent, ack? ->
        {[{:peon, drop_preambles(agent), ack?}], false}
    end)
    |> elem(0)
  end

  # The agent's text before more tool calls is a preamble or progress note; the
  # user only reads its answer, the last text of the turn. Tool lines stay.
  defp drop_preambles(messages) do
    {kept, _tool_after?} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, fn
        %{role: :assistant}, {kept, true} -> {kept, true}
        %{role: :tool} = m, {kept, _} -> {[m | kept], true}
        m, {kept, tool_after?} -> {[m | kept], tool_after?}
      end)

    kept
  end

  # What the peon is on right now, in plain words, from its latest tool call.
  defp doing(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role != :user))
    |> Enum.find(&(&1.role == :tool))
    |> case do
      nil -> "Thinking it over…"
      %{text: text} -> text |> split_tool() |> activity()
    end
  end

  defp activity({"bash", command}) do
    cond do
      command =~ "mix test" -> "Running the tests…"
      command =~ "mix format" -> "Tidying up…"
      command =~ ~r/mix (compile|deps)/ -> "Building…"
      command =~ "curl" -> "Looking at the page…"
      command =~ "preview.log" -> "Reading the preview's log…"
      true -> "Running a command…"
    end
  end

  defp activity({tool, path}) when tool in ~w(edit write patch apply_patch multiedit),
    do: "Changing #{path |> String.split(" ") |> Enum.map_join(", ", &Path.basename/1)}…"

  defp activity({tool, _}) when tool in ~w(read glob grep list), do: "Reading the code…"
  defp activity({"todowrite", _}), do: "Making a plan…"
  defp activity({"peon_submit_changeset", _}), do: "Handing in the change…"
  defp activity({"peon_restart_preview", _}), do: "Restarting the preview…"
  defp activity({"peon_runtime", _}), do: "Checking the running app…"
  defp activity({"peon_secrets", _}), do: "Checking the keys…"
  defp activity({"peon_request_secret", _}), do: "Asking you for a key…"
  defp activity(_), do: "Working on it…"

  attr :block, :any, required: true

  defp block(%{block: {:user, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <div class="bubble-user">{@message.text}</div>
    """
  end

  defp block(%{block: {:peon, messages, ack?}} = assigns) do
    assigns = assign(assigns, messages: messages, ack?: ack?)

    ~H"""
    <div class="say-peon-turn">
      <Layouts.mark size={28} />
      <div class="flex-1 min-w-0 flex flex-col gap-2">
        <div class="text-[13px] font-semibold leading-[18px]">Peon</div>
        <div :if={@ack?} class="say-agent">Zug zug.</div>
        <.message :for={m <- @messages} message={m} />
      </div>
    </div>
    """
  end

  attr :message, :map, required: true

  defp message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="say-agent">{String.replace(@message.text, ~r/\A\s*zug zug\.?\s*/i, "")}</div>
    """
  end

  defp message(%{message: %{role: :tool, detail: detail}} = assigns)
       when is_binary(detail) and detail != "" do
    assigns = assign(assigns, tool: split_tool(assigns.message.text))

    ~H"""
    <details class="result" open={@message[:peon?]}>
      <summary class="result-btn">
        <.icon name="hero-chevron-right" class="size-3.5 chev" />
        <span class="mono font-medium text-[var(--text-2)]">{elem(@tool, 0)}</span>
        <span class={["truncate", @message[:status] == "error" && "text-[var(--err)]"]}>{elem(
          @tool,
          1
        )}</span>
      </summary>
      <pre class={["out mono", @message[:peon?] && "peon"]}>{@message.detail}</pre>
    </details>
    """
  end

  defp message(%{message: %{role: :tool}} = assigns) do
    assigns = assign(assigns, tool: split_tool(assigns.message.text))

    ~H"""
    <div class={["tool mono", @message[:status] == "error" && "err"]}>
      <span class="ar">→</span> <span class="nm">{elem(@tool, 0)}</span> {elem(@tool, 1)}
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div class="say-error">{@message.text}</div>
    """
  end

  defp split_tool(text) do
    case String.split(text, " ", parts: 2) do
      [name, rest] -> {name, rest}
      [name] -> {name, ""}
    end
  end

  attr :changeset, :map, required: true
  attr :landed?, :boolean, required: true
  attr :held, :list
  attr :step, :any
  attr :envs, :map, required: true

  defp changeset_card(assigns) do
    verify = assigns.changeset.verify

    steps =
      (assigns.changeset.checks["steps"] || []) ++
        if(assigns.landed? and verify,
          do: [Map.put(verify, "name", "test") |> Map.put_new("duration_ms", nil)],
          else: []
        )

    assigns =
      assign(assigns, steps: steps, flow: flow(assigns.changeset, assigns.landed?, assigns.envs))

    ~H"""
    <section class="framed ws-cs" aria-label="Current changeset">
      <div class="flex items-center gap-2.5 flex-wrap min-h-9">
        <span class="text-[var(--rust)] flex"><.icon
          name="hero-arrows-right-left"
          class="size-[18px]"
        /></span>
        <h2 class="m-0 text-[15px] leading-[22px] font-semibold">Changeset #{@changeset.id}</h2>
        <span class={["st", cs_tone(@changeset, @landed?)]}>
          <span :if={@changeset.status in ["checking", "proposed"]} class="dot"></span>{cs_status(
            @changeset,
            @landed?
          )}
        </span>
        <span :if={@landed?} class={["st", verify_tone(@changeset)]}>tests {verify_text(@changeset)}</span>
      </div>
      <div class="truncate muted text-[13px]">{@changeset.intent}</div>
      <div :if={@steps != [] or @changeset.status == "checking"} class="ws-steps">
        <div :for={step <- @steps} class={["step", step_kind(step["status"])]}>
          <span class="i"><.step_icon status={step["status"]} /></span>
          <span class="mono">{step["name"]}</span>
          <span class="t mono">{seconds(step["duration_ms"])}</span>
        </div>
        <div :if={@changeset.status == "checking"} class="step run">
          <span class="i"><.step_icon status="running" /></span>
          <span class="mono">{step_text(@step)}</span>
        </div>
      </div>
      <div :if={@held not in [nil, []] and not @landed?} class="text-[13px] text-[var(--warn)]">
        Needs your review: {Enum.join(@held, "; ")}
      </div>
      <div class="mrg">
        <div class="flow mono">
          <span class={@flow.dev}>dev #{@changeset.id}</span>
          <.icon name="hero-arrow-right" class="size-3.5" />
          <span class={@flow.main}>main</span>
          <.icon name="hero-arrow-right" class="size-3.5" />
          <span class={@flow.staging}>staging</span>
          <.icon name="hero-arrow-right" class="size-3.5" />
          <span class={@flow.prod}>prod</span>
        </div>
        <button
          :if={@changeset.status == "passed" and not @landed?}
          phx-click="land"
          phx-value-id={@changeset.id}
          data-kb-key="a"
          data-kb-label="Land changeset"
          data-kb-group="Ship"
          data-confirm="Land this changeset on main?"
          class="btn btn-primary ml-auto"
        >
          <.icon name="hero-arrows-right-left" class="size-4" /> Land on main
        </button>
      </div>
    </section>
    """
  end

  # Which stages a changeset has reached: landed, and live on staging and prod.
  defp flow(cs, landed?, envs) do
    live? = fn env ->
      landed? and match?(%{deployed: id} when id != nil, envs[env]) and
        Code.ancestor?(cs.id, envs[env].deployed)
    end

    %{
      dev: "on",
      main: landed? && "on",
      staging: live?.("staging") && "on",
      prod: live?.("prod") && "on"
    }
  end

  attr :status, :string, required: true

  defp step_icon(%{status: "passed"} = assigns),
    do: ~H|<.icon name="hero-check" class="size-[15px]" />|

  defp step_icon(%{status: "failed"} = assigns),
    do: ~H|<.icon name="hero-x-mark" class="size-[15px]" />|

  defp step_icon(%{status: "running"} = assigns),
    do: ~H|<.icon name="hero-arrow-path" class="size-[15px] spin" />|

  defp step_icon(assigns), do: ~H|<.icon name="hero-minus-small" class="size-[15px]" />|

  defp step_kind("passed"), do: "pass"
  defp step_kind("failed"), do: "fail"
  defp step_kind(_), do: "wait"

  attr :main, :map
  attr :culprit, :map
  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :auto_promote, :boolean, required: true
  attr :promote, :any
  attr :open_incidents, :integer, required: true

  # Under the chats: main's tests, staging and prod, and the way to incidents.
  defp ship_status(assigns) do
    ~H"""
    <div class="ws-ship" id="ship-status">
      <div class="eyebrow px-1.5 pb-1.5">Ship</div>
      <div :if={@main} class="ws-ship-row">
        <span class="mono">main #{@main.id}</span>
        <span class={["st", verify_tone(@main)]}>tests {verify_text(@main)}</span>
      </div>
      <div :if={@culprit} class="ws-ship-row text-[var(--err)]" title={@culprit.intent}>
        <span>broken by #{@culprit.id}</span>
      </div>
      <div :for={name <- @env_names} class="ws-ship-row">
        <span class="mono">
          {name}<span :if={info = @envs[name]}>{if(info.deployed, do: " ##{info.deployed}")}</span>
          <span
            :if={name == "prod" and @auto_promote}
            class="tag ml-1"
            title="Prod follows every healthy staging deploy"
          >auto</span>
        </span>
        <%= if info = @envs[name] do %>
          <span class={["st", st_tone(info.status)]}><span class="dot"></span>{env_text(info)}</span>
        <% else %>
          <span class="st idle">off</span>
        <% end %>
      </div>
      <button
        :if={@promote}
        phx-click="promote"
        phx-value-id={@promote}
        data-kb-key="P"
        data-kb-label="Promote to prod"
        data-kb-group="Ship"
        data-confirm={"Deploy ##{@promote} (healthy on staging) to prod?"}
        class="btn btn-primary btn-sm w-full mt-1"
      >
        Promote #{@promote} to prod
      </button>
      <button
        phx-click="toggle_ship"
        data-kb-key="s"
        data-kb-label="Incidents · deploys"
        data-kb-group="Ship"
        class={["xlink mt-1", @open_incidents > 0 && "text-[var(--err)]"]}
      >
        {@open_incidents} {if(@open_incidents == 1, do: "incident", else: "incidents")} · deploys
      </button>
    </div>
    """
  end

  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :incidents, :list, required: true
  attr :deploys, :map, required: true
  attr :auto_promote, :boolean, required: true

  defp ship_panel(assigns) do
    ~H"""
    <section id="ship-panel" class="ws-panel" aria-label="Incidents and deploys">
      <div class="sec-h">
        <h2 class="m-0 text-[15px] font-semibold">Incidents and deploys</h2>
        <button type="button" phx-click="toggle_ship" class="icon-btn sm" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <div class="eyebrow pt-2 pb-1">Incidents</div>
      <ul class="rows">
        <li :if={@incidents == []} class="muted">No errors reported.</li>
        <li :for={i <- @incidents} class="items-start!">
          <span class="tag shrink-0">{i.env}</span>
          <div class="flex-1 min-w-0">
            <div class={["truncate", i.status != "resolved" && "text-[var(--err)]"]} title={i.detail}>
              {i.title}
            </div>
            <div class="meta">
              {i.count}× · {i.status}
              <.link :if={i.chat_id} patch={~p"/c/#{i.chat_id}"} data-kb="row" class="xlink">chat</.link>
            </div>
          </div>
          <button
            :if={i.status == "open"}
            phx-click="fix_incident"
            phx-value-id={i.id}
            data-kb="row"
            class="btn btn-secondary btn-sm"
          >
            Fix with AI
          </button>
          <button
            :if={i.status != "resolved"}
            phx-click="resolve_incident"
            phx-value-id={i.id}
            data-kb="row"
            class="btn btn-ghost btn-sm"
          >
            Resolve
          </button>
        </li>
      </ul>
      <div :for={name <- @env_names} class="pt-5">
        <div class="sec-h">
          <span class="flex items-center gap-3">
            <span class="eyebrow">{name}</span>
            <span :if={stats = @envs[name] && @envs[name].stats} class="meta mono">
              {stats["process_count"]} procs · {mb(stats["total"])} MB · rq {stats["run_queue"]}
            </span>
          </span>
          <label :if={name == "prod"} class="check">
            <input
              id="auto-promote"
              type="checkbox"
              data-kb="row"
              checked={@auto_promote}
              phx-click="toggle_auto_promote"
            /> auto-promote healthy staging
          </label>
          <span :if={!(@envs[name] && @envs[name].deployed)} class="meta">nothing deployed yet</span>
          <button
            :if={@envs[name] && @envs[name].deployed}
            phx-click="restart_env"
            phx-value-env={name}
            data-kb="row"
            class="btn btn-ghost btn-sm"
          >
            Restart
          </button>
        </div>
        <ul class="rows">
          <li :for={d <- @deploys[name] || []}>
            <span class="mono">#{d.changeset_id}</span>
            <span class="meta">{d.mode}</span>
            <span class={["st", deploy_tone(d.status)]}><span class="dot"></span>{d.status}</span>
            <span class="meta truncate" title={d.detail}>{d.detail}</span>
          </li>
        </ul>
        <pre
          :if={@envs[name] && @envs[name].deployed}
          title="A remote IEx shell on the running node"
          class="out mono mt-2"
        >{@envs[name].attach}</pre>
      </div>
    </section>
    """
  end

  # Secrets the agent asked for that nobody has set yet (for one chat, or all).
  defp asked(secrets, chat_id \\ nil),
    do: Enum.filter(secrets, &(not &1.set? and (chat_id == nil or &1.chat_id == chat_id)))

  defp secrets_text(secrets) do
    case {length(secrets), length(asked(secrets))} do
      {0, _} -> "Secrets"
      {n, 0} -> "#{n} #{if n == 1, do: "secret", else: "secrets"}"
      {n, a} -> "#{n - a} set · #{a} asked for"
    end
  end

  attr :secrets, :list, required: true
  attr :key, :integer, required: true

  # In the chat: the keys the agent asked for, with a box to paste each into.
  defp connect_card(assigns) do
    ~H"""
    <section class="framed ws-connect" aria-label="Keys the app needs">
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="m-0 text-[15px] font-semibold">Peon needs a key</h2>
        <span class="meta">kept in Peon, never in the code</span>
      </div>
      <.form
        :for={s <- @secrets}
        for={%{}}
        id={"connect-#{s.name}-#{@key}"}
        phx-submit="set_secret"
        class="ws-connect-row"
      >
        <input type="hidden" name="name" value={s.name} />
        <label class="flex flex-col min-w-0 flex-1 gap-1">
          <span class="mono text-[13px] font-medium">{s.name}</span>
          <span :if={s.why} class="meta">{s.why}</span>
          <input
            type="password"
            name="value"
            class="field"
            autocomplete="off"
            required
            aria-label={"Value for #{s.name}"}
          />
        </label>
        <button class="btn btn-primary btn-sm" data-kb="row">Save</button>
      </.form>
    </section>
    """
  end

  attr :secrets, :list, required: true
  attr :key, :integer, required: true

  defp secrets_panel(assigns) do
    ~H"""
    <section id="secrets-panel" class="ws-panel" aria-label="Secrets">
      <div class="sec-h">
        <h2 class="m-0 text-[15px] font-semibold">Secrets</h2>
        <button type="button" phx-click="toggle_secrets" class="icon-btn sm" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <p class="meta m-0 pb-3">
        API keys, tokens and passwords. The preview, staging and prod get each one as an
        environment variable and restart when one changes. The agent sees names only.
      </p>
      <ul class="rows">
        <li :if={@secrets == []} class="muted">No secrets yet.</li>
        <li :for={s <- @secrets} class="items-start!">
          <div class="flex-1 min-w-0 flex flex-col gap-1.5">
            <div class="flex items-center gap-2">
              <span class="mono font-medium">{s.name}</span>
              <span class={["st", if(s.set?, do: "ok", else: "warn")]}>
                <span class="dot"></span>{if s.set?, do: "set", else: "asked for"}
              </span>
            </div>
            <span :if={s.why} class="meta">{s.why}</span>
            <span :if={s.set? && s.set_by} class="meta">by {s.set_by}</span>
            <.form
              for={%{}}
              id={"secret-#{s.name}-#{@key}"}
              phx-submit="set_secret"
              class="flex gap-2"
            >
              <input type="hidden" name="name" value={s.name} />
              <input
                type="password"
                name="value"
                class="field h-8!"
                autocomplete="off"
                required
                placeholder={if s.set?, do: "New value", else: "Value"}
                aria-label={"Value for #{s.name}"}
              />
              <button class="btn btn-secondary btn-sm" data-kb="row">
                {if s.set?, do: "Replace", else: "Save"}
              </button>
            </.form>
          </div>
          <button
            phx-click="delete_secret"
            phx-value-name={s.name}
            data-kb="row"
            data-confirm={"Remove #{s.name}? The app loses it on its next restart."}
            class="btn btn-ghost btn-sm"
          >
            Remove
          </button>
        </li>
      </ul>
      <div class="eyebrow pt-5 pb-2">Add a secret</div>
      <.form for={%{}} id={"secret-new-#{@key}"} phx-submit="set_secret" class="flex flex-col gap-2">
        <input
          type="text"
          name="name"
          class="field mono"
          placeholder="NAME, like SLACK_TOKEN"
          autocomplete="off"
          required
          aria-label="Name"
        />
        <input
          type="password"
          name="value"
          class="field"
          placeholder="Value"
          autocomplete="off"
          required
          aria-label="Value"
        />
        <button class="btn btn-primary btn-sm self-start" data-kb="row">Add</button>
      </.form>
    </section>
    """
  end

  defp initials(nil), do: "?"

  defp initials(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp seconds(nil), do: ""
  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp step_text({step, status}), do: "#{step} #{status}"
  defp step_text(_), do: "checking…"

  defp cs_status(_cs, true), do: "on main"
  defp cs_status(%{status: "passed"}, false), do: "passed"
  defp cs_status(cs, false), do: cs.status

  defp cs_tone(_cs, true), do: "ok"
  defp cs_tone(%{status: "passed"}, _), do: "ok"
  defp cs_tone(%{status: "failed"}, _), do: "err"
  defp cs_tone(%{status: "superseded"}, _), do: "idle"
  defp cs_tone(_, _), do: "warn"

  # The imported template is the baseline: never tested, counted as passing.
  defp verify_text(%{verify: %{"status" => status}}), do: status
  defp verify_text(%{parent_id: nil}), do: "baseline"
  defp verify_text(_), do: "pending"

  defp verify_tone(%{verify: %{"status" => "passed"}}), do: "ok"
  defp verify_tone(%{verify: %{"status" => "failed"}}), do: "err"
  defp verify_tone(%{parent_id: nil}), do: "ok"
  defp verify_tone(_), do: "warn"

  defp env_text(%{status: :watching, deploy: %{target: id}}), do: "watching ##{id}"
  defp env_text(%{status: :loading, deploy: %{target: id}}), do: "hot-loading ##{id}"
  defp env_text(%{status: :booting, deploy: %{target: id}}), do: "starting ##{id}"
  defp env_text(%{status: {:crashed, _}}), do: "crashed"
  defp env_text(%{status: status}), do: to_string(status)

  defp st_tone(:running), do: "ok"

  defp st_tone(status) when status in [:starting, :loading, :booting, :watching, :attaching],
    do: "warn"

  defp st_tone(status) when status in [nil, :stopped, :no_pack], do: "idle"
  defp st_tone(_), do: "err"

  defp preview_word({:crashed, _}), do: "stopped"
  defp preview_word(:no_pack), do: "no preview"
  defp preview_word({:pack_error, _}), do: "pack error"
  defp preview_word(status), do: to_string(status)

  defp deploy_tone("healthy"), do: "ok"
  defp deploy_tone("failed"), do: "err"
  defp deploy_tone(_), do: "warn"

  defp mb(nil), do: "?"
  defp mb(bytes), do: div(bytes, 1_048_576)

  defp preview_message(:starting),
    do: "Starting the preview (the first start fetches and compiles dependencies)…"

  defp preview_message({:crashed, code}),
    do: "The preview stopped (exit #{code}). Check the logs or restart it."

  defp preview_message(:no_pack),
    do: "This repo has no .peon/preview.json yet. Ask the agent to add one for a preview."

  defp preview_message({:pack_error, message}),
    do: "The preview pack (.peon/preview.json) needs fixing: #{message}"

  defp preview_message(_), do: ""

  defp stopped_message(:idle),
    do:
      "The agent and preview stopped after 30 minutes without use. Send a message or start them again."

  defp stopped_message(:room),
    do:
      "Stopped to make room: at most #{Application.get_env(:peon, :max_running_chats, 3)} chats run at once. Send a message or start it again."

  defp stopped_message(_),
    do: "The agent and preview stopped. Send a message or start them again."

  defp env_message(env, %{status: {:crashed, _}}),
    do: "#{String.capitalize(env)} stopped. Check its logs."

  defp env_message(env, %{status: :running, deployed: id}),
    do:
      "#{String.capitalize(env)} runs ##{id} with its real security headers, so it opens in its own tab."

  defp env_message(env, info), do: "#{String.capitalize(env)}: #{env_text(info)}"
end
