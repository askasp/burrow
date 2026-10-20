defmodule PeonWeb.ProjectLive do
  @moduledoc """
  The workspace, Peon's home screen, laid out as the Peon UI kit's "4 ·
  Peon: home" board: the project rail (every project the user can open, from
  Burrow), then the project bar, the chat tabs with the open chat and its
  changeset, and the preview. The preview switches between the chat's dev
  preview and what is live (staging and prod in a pipeline project), or
  gives way to "Deploys and usage".

  A project has up to four chats (`Peon.Chats.max/0`), each one changeset;
  `Peon.Activity` says where each stands. An empty chat starts its agent
  and preview with its first message.
  """

  use PeonWeb, :live_view

  import PeonWeb.ProjectLive.Components

  alias Peon.{Activity, Chat, Chats, Code, Env, Incidents, Project, Secrets, Ship, Store}
  alias Peon.Verifier

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Chats.subscribe()
      Store.subscribe()
      Peon.Checks.subscribe()
      Env.subscribe()
      Incidents.subscribe()
      Secrets.subscribe()
      Peon.Burrow.subscribe()
    end

    {:ok,
     socket
     |> assign(project: Project.get(), repo?: Peon.Source.repo?())
     |> assign(burrow_url: Application.get_env(:peon, :burrow_url))
     # The project rail and this project's sharing, from Burrow
     |> assign(rail: [], sharing: nil, rail_open: false, rail_set?: false)
     |> load_rail()
     |> assign(busy: if(connected?(socket), do: Chat.busy_ids(), else: MapSet.new()))
     |> assign(chat: nil, tab: nil, info: nil, view: "dev")
     |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
     # Why the open chat stopped (Peon.Chat's {:stopped, reason}), while it is
     |> assign(stopped: nil)
     |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
     |> assign(changeset: nil, landed?: false, held: nil, form: to_form(%{"text" => ""}))
     # The "/" menu: the chat's commands and skills, and those matching the box
     |> assign(slash_items: [], slash: [])
     # "Deploys and usage" in place of the preview; one dialog at a time
     |> assign(overview: false, dialog: nil, new_project: new_project(), creating: false)
     |> assign(env_names: Ship.env_names(), live_only?: Ship.live_only?())
     |> assign(secrets: Secrets.list(), secrets_key: 0)
     # Phones: one pane at a time
     |> assign(pane: "chat")
     |> assign(envs: Map.new(Ship.env_names(), &{&1, Env.info(&1)}))
     |> load_tabs()
     |> load_ship()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Chats.get(id) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/")}

      chat ->
        if old = socket.assigns.chat,
          do: Phoenix.PubSub.unsubscribe(Peon.PubSub, "chat:#{old.id}")

        if connected?(socket), do: Chat.subscribe(id)

        socket =
          socket
          |> assign(chat: chat, info: nil, start_error: nil, show_logs: false, pending: nil)
          |> assign(slash_items: [], slash: [], stopped: nil, starting: false, step: nil)
          |> select_tab()
          |> load_changeset()
          |> default_view()

        # An empty chat starts its agent with its first message.
        if connected?(socket) and chat.started_at,
          do: {:noreply, start_chat(socket)},
          else: {:noreply, socket}
    end
  end

  # The workspace opens on the first chat, or a new empty one.
  def handle_params(_params, _uri, socket) do
    case socket.assigns.tabs do
      [first | _] ->
        {:noreply, push_patch(socket, to: ~p"/c/#{first.chat.id}", replace: true)}

      [] ->
        case Chats.create_empty(socket.assigns.user) do
          {:ok, chat} -> {:noreply, push_patch(socket, to: ~p"/c/#{chat.id}", replace: true)}
          {:error, :full} -> {:noreply, socket}
        end
    end
  end

  defp start_chat(socket) do
    id = socket.assigns.chat.id

    socket
    |> assign(starting: true, stopped: nil, start_error: nil)
    |> start_async(:chat, fn -> Chat.ensure_started(id) end)
  end

  @impl true
  def handle_async(:chat, {:ok, {:ok, info}}, socket) do
    socket = socket |> assign(info: info, starting: false) |> default_view()

    case socket.assigns.pending do
      nil -> {:noreply, socket}
      text -> {:noreply, socket |> assign(pending: nil) |> prompt(text)}
    end
  end

  def handle_async(:chat, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, starting: false, start_error: start_error(reason))}
  end

  def handle_async(:chat, {:exit, reason}, socket) do
    {:noreply, assign(socket, starting: false, start_error: start_error(reason))}
  end

  def handle_async(:rail, {:ok, rail}, socket) do
    socket = assign(socket, rail: rail.projects, sharing: rail.project)

    # The user's choice, until they toggle it here
    if socket.assigns.rail_set?,
      do: {:noreply, socket},
      else: {:noreply, assign(socket, rail_open: rail.rail_open)}
  end

  def handle_async(:rail, {:exit, _}, socket), do: {:noreply, socket}

  def handle_async(:create, {:ok, {:ok, url}}, socket),
    do: {:noreply, redirect(socket, external: url)}

  def handle_async(:create, {:ok, {:error, message}}, socket),
    do: {:noreply, socket |> assign(creating: false) |> put_flash(:error, message)}

  def handle_async(:create, {:exit, _}, socket),
    do:
      {:noreply, socket |> assign(creating: false) |> put_flash(:error, "Burrow did not answer.")}

  def handle_async(:burrow, {:ok, {:ok, text}}, socket),
    do: {:noreply, socket |> assign(dialog: nil) |> info(text) |> load_rail()}

  def handle_async(:burrow, {:ok, {:error, message}}, socket),
    do: {:noreply, put_flash(socket, :error, message)}

  def handle_async(:burrow, {:exit, _}, socket),
    do: {:noreply, put_flash(socket, :error, "Burrow did not answer.")}

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)
    %{chat: chat, tab: tab} = socket.assigns

    cond do
      text == "" or chat == nil or closed?(tab) ->
        {:noreply, socket}

      socket.assigns.info && !socket.assigns.stopped ->
        {:noreply, socket |> assign(form: to_form(%{"text" => ""}), slash: []) |> prompt(text)}

      socket.assigns.starting ->
        {:noreply, assign(socket, pending: text, form: to_form(%{"text" => ""}))}

      true ->
        {:noreply,
         socket |> assign(pending: text, form: to_form(%{"text" => ""})) |> start_chat()}
    end
  end

  def handle_event("typing", %{"text" => text}, socket), do: {:noreply, slash_menu(socket, text)}

  def handle_event("wake", _params, socket), do: {:noreply, start_chat(socket)}

  def handle_event("new_chat", _params, socket) do
    case Chats.create_empty(socket.assigns.user) do
      {:ok, chat} -> {:noreply, push_patch(socket, to: ~p"/c/#{chat.id}")}
      {:error, :full} -> {:noreply, put_flash(socket, :error, full_text())}
    end
  end

  # Closing a chat deletes it (Peon.Chat.delete/1): its agent, preview and
  # workspace go; what it merged stays. Stopping a repo preview can take
  # minutes, so that runs on its own.
  def handle_event("close_chat", %{"id" => id}, socket) do
    Task.Supervisor.start_child(Peon.TaskSupervisor, fn -> Chat.delete(id) end)
    {:noreply, socket}
  end

  def handle_event("toggle_rail", _params, socket) do
    open? = !socket.assigns.rail_open
    user = socket.assigns.user

    Task.Supervisor.start_child(Peon.TaskSupervisor, fn ->
      Peon.Burrow.put_rail_open(user, open?)
    end)

    {:noreply, assign(socket, rail_open: open?, rail_set?: true)}
  end

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

  def handle_event("pick_slash", %{"name" => name}, socket) do
    {:noreply, socket |> assign(slash: []) |> push_event("slash:pick", %{text: "/#{name} "})}
  end

  def handle_event("interrupt", _params, socket) do
    Chat.interrupt(socket.assigns.chat.id)
    {:noreply, socket}
  end

  def handle_event("land", %{"id" => id}, socket) do
    case Ship.merge(String.to_integer(id), socket.assigns.user) do
      {:ok, _cs} ->
        {:noreply, socket |> load_changeset() |> load_tabs()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not merge: #{inspect(reason)}")}
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
        {:noreply, socket |> info("Deploying ##{id} to prod.") |> assign(view: "prod")}

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
    case Incidents.fix(Incidents.get(String.to_integer(id)), socket.assigns.user) do
      {:ok, incident} -> {:noreply, push_patch(socket, to: ~p"/c/#{incident.chat_id}")}
      {:error, :full} -> {:noreply, put_flash(socket, :error, full_text())}
    end
  end

  def handle_event("resolve_incident", %{"id" => id}, socket) do
    Incidents.resolve(Incidents.get(String.to_integer(id)))
    {:noreply, socket}
  end

  def handle_event("toggle_overview", _params, socket),
    do: {:noreply, socket |> update(:overview, &(!&1)) |> load_ship()}

  def handle_event("dialog", %{"dialog" => dialog}, socket)
      when dialog in ~w(new_project share hand_over secrets) do
    {:noreply,
     assign(socket, dialog: String.to_existing_atom(dialog), new_project: new_project())}
  end

  def handle_event("close_dialog", _params, socket), do: {:noreply, assign(socket, dialog: nil)}

  def handle_event("new_project_change", %{"project" => params}, socket),
    do: {:noreply, update(socket, :new_project, &Map.merge(&1, new_project_params(params)))}

  def handle_event("toggle_more", _params, socket),
    do: {:noreply, update(socket, :new_project, &%{&1 | more: !&1.more})}

  def handle_event("create_project", %{"project" => params}, socket) do
    p = Map.merge(socket.assigns.new_project, new_project_params(params))
    user = socket.assigns.user

    if p.name == "" or socket.assigns.creating do
      {:noreply, socket}
    else
      basic =
        if p.auth == "basic" and p.repo_url == "",
          do: %{"basic_username" => p.basic_username, "basic_password" => p.basic_password},
          else: %{}

      attrs =
        Map.merge(
          %{"name" => p.name, "repo_url" => p.repo_url, "team_id" => p.team_id, "auth" => p.auth},
          basic
        )

      {:noreply,
       socket
       |> assign(creating: true, new_project: p)
       |> start_async(:create, fn -> Peon.Burrow.create_project(user, attrs) end)}
    end
  end

  def handle_event("share", %{"share" => %{"team_id" => team_id}}, socket) do
    user = socket.assigns.user
    team_id = if team_id == "", do: nil, else: team_id

    {:noreply,
     start_async(socket, :burrow, fn ->
       with :ok <- Peon.Burrow.share(user, team_id) do
         {:ok, if(team_id, do: "Shared.", else: "Only you can open it now.")}
       end
     end)}
  end

  def handle_event("hand_over", %{"hand_over" => %{"user_id" => user_id}}, socket) do
    user = socket.assigns.user

    {:noreply,
     start_async(socket, :burrow, fn ->
       with :ok <- Peon.Burrow.hand_over(user, user_id) do
         {:ok, "Handed over. Peon restarts on their AI login."}
       end
     end)}
  end

  # Burrow records it and has this Peon do it; without Burrow, Peon does it.
  def handle_event("add_envs", _params, socket) do
    user = socket.assigns.user
    add = if socket.assigns.burrow_url, do: &Peon.Burrow.add_envs/1, else: &Ship.add_envs/1

    {:noreply,
     start_async(socket, :burrow, fn ->
       with :ok <- add.(user) do
         {:ok, "Staging and prod are set up: main goes to staging, then you promote."}
       end
     end)}
  end

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

  def handle_event("pane", %{"pane" => pane}, socket) when pane in ["chat", "preview"],
    do: {:noreply, assign(socket, pane: pane)}

  def handle_event("view", %{"view" => view}, socket) when view in ["dev", "staging", "prod"],
    do:
      {:noreply,
       socket
       |> assign(view: view, overview: false)
       |> update(:frame_key, &(&1 + 1))
       |> load_logs()}

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

  def handle_info({:chat_busy, id, busy?}, socket) do
    busy =
      if busy?,
        do: MapSet.put(socket.assigns.busy, id),
        else: MapSet.delete(socket.assigns.busy, id)

    {:noreply, socket |> assign(busy: busy) |> load_tabs()}
  end

  def handle_info({:chat_started, id}, socket) do
    socket = load_tabs(socket)

    if socket.assigns.chat && socket.assigns.chat.id == id,
      do:
        {:noreply, socket |> assign(chat: Chats.get(id) || socket.assigns.chat) |> select_tab()},
      else: {:noreply, socket}
  end

  def handle_info({:chat_created, _}, socket), do: {:noreply, load_tabs(socket)}

  def handle_info({:chat_deleted, id}, socket) do
    socket = load_tabs(socket)

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

  def handle_info(:rail_changed, socket), do: {:noreply, load_rail(socket)}

  def handle_info({:env, name, info}, socket) do
    socket = update(socket, :envs, &Map.put(&1, name, info))
    # Stats arrive every few seconds; only reload the lists when something moved.
    if info.deploy || socket.assigns.overview,
      do: {:noreply, socket |> load_ship() |> load_tabs()},
      else: {:noreply, socket}
  end

  def handle_info({:incident, _}, socket), do: {:noreply, load_ship(socket)}

  def handle_info({:secrets, secrets}, socket), do: {:noreply, assign(socket, secrets: secrets)}

  def handle_info({:check_step, _id, step, status}, socket),
    do: {:noreply, socket |> assign(step: {step, status}) |> load_changeset()}

  def handle_info(:clear_info, socket), do: {:noreply, clear_flash(socket, :info)}

  # Store and checks events: refs moved, changesets checked or landed.
  def handle_info(_msg, socket) do
    {:noreply,
     socket
     |> assign(env_names: Ship.env_names(), live_only?: Ship.live_only?())
     |> load_changeset()
     |> load_tabs()
     |> load_ship()}
  end

  # Info flashes clear themselves so they don't cover the work; errors stay.
  defp info(socket, text) do
    Process.send_after(self(), :clear_info, 4_000)
    put_flash(socket, :info, text)
  end

  defp full_text, do: "Up to #{Chats.max()} chats. Merge or close one first."

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

  defp load_logs(%{assigns: %{view: "dev", chat: %{id: id}}} = socket) do
    case Chat.logs(id) do
      {:ok, logs} -> assign(socket, logs: logs)
      _ -> socket
    end
  end

  defp load_logs(%{assigns: %{view: env}} = socket) when env in ["staging", "prod"],
    do: assign(socket, logs: Env.logs(env))

  defp load_logs(socket), do: socket

  defp load_rail(socket) do
    user = socket.assigns.user

    if connected?(socket),
      do: start_async(socket, :rail, fn -> Peon.Burrow.rail(user) end),
      else: socket
  end

  # The chat tabs, each with its changeset and phase (Peon.Activity).
  defp load_tabs(socket),
    do: socket |> assign(tabs: Activity.chats(socket.assigns.busy)) |> select_tab()

  defp select_tab(%{assigns: %{chat: nil}} = socket), do: assign(socket, tab: nil)

  defp select_tab(socket) do
    id = socket.assigns.chat.id
    assign(socket, tab: Enum.find(socket.assigns.tabs, &(&1.chat.id == id)))
  end

  defp load_changeset(%{assigns: %{chat: nil}} = socket), do: socket

  defp load_changeset(socket) do
    main_id = with(%{changeset_id: id} <- Code.ref("main"), do: id)
    changeset = Chats.latest_changeset(socket.assigns.chat.id)

    assign(socket,
      changeset: changeset,
      landed?: changeset != nil and Code.ancestor?(changeset.id, main_id),
      held:
        if(changeset != nil and changeset.status == "passed" and not Ship.live_only?(),
          do: Ship.review_reasons(changeset)
        )
    )
  end

  defp load_ship(socket) do
    socket =
      assign(socket,
        incidents: Incidents.list(),
        culprit: Verifier.culprit(),
        auto_promote: Project.settings()["auto_promote"] == true,
        nothing_built?: not socket.assigns.repo? and Code.ref("prod") == nil
      )

    if socket.assigns.overview,
      do: assign(socket, deploys: deploys(socket.assigns.env_names)),
      else: assign(socket, deploys: [])
  end

  # The latest deploys over all environments, one row per changeset, with
  # where it is now and what was asked for.
  defp deploys(env_names) do
    on = Map.new(env_names, &{&1, with(%{changeset_id: id} <- Code.ref(&1), do: id)})

    env_names
    |> Enum.flat_map(&Env.deploys(&1, 8))
    |> Enum.filter(&(&1.status == "healthy"))
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.uniq_by(& &1.changeset_id)
    |> Enum.take(8)
    |> Enum.map(fn d ->
      where =
        Enum.find(Enum.reverse(env_names), fn env ->
          on[env] && Code.ancestor?(d.changeset_id, on[env])
        end)

      intent =
        case Code.changeset(d.changeset_id) do
          {:ok, cs} -> cs.intent
          _ -> ""
        end

      %{id: d.changeset_id, intent: intent, where: where, at: d.inserted_at}
    end)
  end

  # The chat's dev preview while it has one; else what is live.
  defp default_view(socket) do
    if dev?(socket.assigns), do: assign(socket, view: "dev"), else: assign(socket, view: "prod")
  end

  defp dev?(%{chat: chat, tab: tab}),
    do: chat != nil and chat.started_at != nil and not closed?(tab)

  defp closed?(%{phase: phase}), do: phase in ~w(landing staged live)
  defp closed?(_tab), do: false

  defp new_project do
    %{
      name: "",
      repo_url: "",
      team_id: "",
      auth: "accounts",
      basic_username: "",
      basic_password: "",
      more: false
    }
  end

  @new_project_fields [
    {"name", :name},
    {"repo_url", :repo_url},
    {"team_id", :team_id},
    {"auth", :auth},
    {"basic_username", :basic_username},
    {"basic_password", :basic_password}
  ]

  defp new_project_params(params) do
    for {key, field} <- @new_project_fields,
        is_binary(params[key]),
        into: %{},
        do: {field, String.trim(params[key])}
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
        view: effective_view(assigns),
        dev?: dev?(assigns),
        promote: promote_target(assigns),
        open_incidents: Enum.count(assigns.incidents, &(&1.status != "resolved")),
        burrow: assigns.burrow_url && assigns.burrow_url <> "/projects"
      )

    assigns = assign(assigns, preview: preview(assigns))

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="ws-root" data-pane={@pane}>
      <div
        class="ws-scrim"
        aria-hidden="true"
        phx-click={JS.remove_class("drawer", to: ".ws-root")}
      >
      </div>
      <.rail rail={rail_items(@rail, @project, @tabs)} open={@rail_open} burrow={@burrow} />

      <div class="ws-main">
        <.project_bar
          project={@project}
          meta={meta(assigns)}
          overview={@overview}
          sharing={@sharing}
          live_only?={@live_only?}
          repo?={@repo?}
          secrets={@secrets}
          open_incidents={@open_incidents}
          pane={@pane}
        />

        <div class="ws-split">
          <main
            class="ws-chat"
            aria-label={"#{@project && @project.name} chats"}
            data-kb-zoom-hide
          >
            <.chat_tabs
              tabs={@tabs}
              chat={@chat}
              project={@project}
              nothing_built?={@nothing_built?}
              repo?={@repo?}
            />

            <div class="ws-scroll" id="messages" phx-hook=".ScrollBottom">
              <div class="ws-thread">
                <div :if={(@chat && @chat.started_at == nil) and @pending == nil} class="ws-hello">
                  <Layouts.mark size={52} />
                  <h2>{hello(@project, @nothing_built?)}</h2>
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
                  <span class="swing text-[var(--rust)]"><.icon name="hero-wrench" class="size-4" /></span>
                  <span class="font-medium shrink-0">Peon is working…</span>
                  <span class="mono muted text-[12.5px] truncate">{doing(@info.messages)}</span>
                  <button
                    phx-click="interrupt"
                    data-kb-key="x"
                    data-kb-label="Stop the agent"
                    data-kb-group="Agent & preview"
                    data-kb-esc
                    class="btn btn-ghost btn-sm ml-auto"
                  >
                    Stop
                  </button>
                </div>
                <div
                  :if={event = event_line(@tab, @live_only?)}
                  class={["evt", event.tone]}
                  role="note"
                >
                  <span class="ln"></span><span class="mono">{event.text}</span><span class="ln"></span>
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
                :if={@changeset && !@repo?}
                changeset={@changeset}
                tab={@tab}
                landed?={@landed?}
                held={@held}
                step={@step}
                live_only?={@live_only?}
                promote={@promote}
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
                  disabled={closed?(@tab)}
                  placeholder={placeholder(@tab, @changeset)}
                >{@form[:text].value}</textarea>
                <div class="cbar">
                  <button
                    :if={@info}
                    type="button"
                    phx-click="toggle_attach"
                    data-kb="row"
                    class="xlink"
                  >
                    Open in opencode
                  </button>
                  <button class="icon-btn ws-send" aria-label="Send" disabled={closed?(@tab)}>
                    <.icon name="hero-arrow-up" class="size-4" />
                  </button>
                </div>
                <pre :if={@info && @show_attach} class="out mono">{@info.attach}</pre>
              </.form>
            </div>
          </main>

          <section class="ws-prev" aria-label="Preview">
            <.overview
              :if={@overview}
              envs={@envs}
              env_names={@env_names}
              live_only?={@live_only?}
              tabs={@tabs}
              info={@info}
              promote={@promote}
              auto_promote={@auto_promote}
              incidents={@incidents}
              deploys={@deploys}
            />
            <.preview_pane
              :if={!@overview}
              preview={@preview}
              view={@view}
              env_names={@env_names}
              live_only?={@live_only?}
              dev?={@dev?}
              changeset={@changeset}
              chat={@chat}
              info={@info}
              frame_key={@frame_key}
              show_logs={@show_logs}
              logs={@logs}
              project={@project}
            />
          </section>
        </div>
      </div>

      <.new_project_dialog
        :if={@dialog == :new_project}
        p={@new_project}
        teams={(@sharing && @sharing.teams) || []}
        creating={@creating}
      />
      <.share_dialog :if={@dialog == :share} sharing={@sharing} project={@project} />
      <.hand_over_dialog :if={@dialog == :hand_over} sharing={@sharing} project={@project} />
      <.secrets_dialog :if={@dialog == :secrets} secrets={@secrets} key={@secrets_key} />
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

  # A view that isn't there falls back to what is live.
  defp effective_view(%{view: "dev"} = assigns), do: if(dev?(assigns), do: "dev", else: "prod")

  defp effective_view(%{view: "staging", env_names: names}),
    do: if("staging" in names, do: "staging", else: "prod")

  defp effective_view(%{view: view}), do: view

  # The rail's tiles; without Burrow, just this project.
  defp rail_items([], project, tabs) when project != nil do
    tile = Activity.project(tabs)

    [
      %{
        id: project.id,
        name: project.name,
        url: "/",
        current: true,
        state: tile["state"],
        label: tile["label"],
        pct: tile["pct"]
      }
    ]
  end

  defp rail_items(rail, _project, _tabs), do: rail

  # "watchtower · live #8 · no staging · shared with Ops"
  defp meta(%{project: nil}), do: ""

  defp meta(assigns) do
    %{project: project, envs: envs, sharing: sharing} = assigns
    tag = fn env -> with(%{deployed: id} when id != nil <- envs[env], do: "##{id}") || "—" end

    parts =
      cond do
        assigns.repo? -> [project.slug, "from #{repo_name()}"]
        assigns.nothing_built? -> [project.slug, "nothing built yet"]
        assigns.live_only? -> [project.slug, "live #{tag.("prod")}", "no staging"]
        true -> [project.slug, "staging #{tag.("staging")}", "prod #{tag.("prod")}"]
      end

    shared = if sharing && sharing.team, do: ["shared with #{sharing.team.name}"], else: []
    Enum.join(parts ++ shared, " · ")
  end

  defp repo_name do
    case Peon.Source.repo() do
      %{url: url} ->
        (URI.parse(url).path || "")
        |> String.trim_leading("/")
        |> String.trim_trailing(".git")

      _ ->
        "a git repo"
    end
  end

  defp hello(project, true), do: "What should #{project && project.name} do?"
  defp hello(project, false), do: "What should change in #{project && project.name}?"

  defp placeholder(%{phase: phase}, _cs) when phase in ~w(landing staged live),
    do: "Merged. Start a new chat for the next change."

  defp placeholder(%{phase: "ready"}, %{id: id}), do: "Add to ##{id}, or merge it"
  defp placeholder(%{phase: "new"}, _cs), do: "Describe the change"
  defp placeholder(_tab, _cs), do: "Message Peon (/ for commands)"

  # The line under the thread once the chat's changeset is merged.
  defp event_line(%{phase: "landing", changeset: %{id: id}}, true),
    do: %{text: "##{id} on main · going live…", tone: nil}

  defp event_line(%{phase: "landing", changeset: %{id: id}}, false),
    do: %{text: "##{id} on main · on its way to staging…", tone: nil}

  defp event_line(%{phase: "staged", changeset: %{id: id}}, _live_only?),
    do: %{text: "##{id} on main · on staging", tone: "ok"}

  defp event_line(%{phase: "live", changeset: %{id: id}}, true),
    do: %{text: "##{id} on main · live", tone: "ok"}

  defp event_line(%{phase: "live", changeset: %{id: id}}, false),
    do: %{text: "##{id} promoted to prod", tone: "ok"}

  defp event_line(_tab, _live_only?), do: nil

  # What the preview pane shows: the chat's dev preview, or staging or prod.
  defp preview(%{view: "dev", info: nil, starting: starting, stopped: stopped} = assigns) do
    %{
      url: nil,
      status: if(starting, do: :starting),
      ref: assigns.changeset && "##{assigns.changeset.id}",
      live?: false,
      message: if(stopped, do: stopped_message(stopped), else: "Starting the preview…"),
      wake: stopped != nil and not starting
    }
  end

  defp preview(%{view: "dev", info: info, changeset: cs, stopped: stopped}) do
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

  defp preview(%{view: env, envs: envs, live_only?: live_only?}) do
    name = env_label(env, live_only?)

    case envs[env] do
      %{deployed: id, status: {:crashed, _}} = info when id != nil ->
        %{
          url: info.url,
          status: info.status,
          ref: "##{id}",
          live?: false,
          down: env,
          message: "#{name} is down"
        }

      %{deployed: id} = info when id != nil ->
        # Real environments keep frame-ancestors 'self' (clickjacking protection),
        # so they open in their own tab instead of the frame.
        %{
          url: info.url,
          status: info.status,
          ref: "##{id}",
          live?: false,
          message: env_message(name, info),
          open: info.status == :running
        }

      info ->
        %{
          url: info && info.url,
          status: nil,
          ref: nil,
          live?: false,
          empty: true,
          message: "Nothing here yet"
        }
    end
  end

  defp promote_target(%{auto_promote: true}), do: nil
  defp promote_target(%{live_only?: true}), do: nil

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
      "Stopped to make room: at most #{Application.get_env(:peon, :max_running_chats, 4)} chats run at once. Send a message or start it again."

  defp stopped_message(_),
    do: "The agent and preview stopped. Send a message or start them again."

  defp env_message(name, %{status: :running, deployed: id}),
    do:
      "#{String.capitalize(name)} runs ##{id} with its real security headers, so it opens in its own tab."

  defp env_message(name, %{deploy: %{target: id}}) when id != nil,
    do: "Deploying ##{id} to #{name}…"

  defp env_message(name, info), do: "#{String.capitalize(name)}: #{env_text(info)}"
end
