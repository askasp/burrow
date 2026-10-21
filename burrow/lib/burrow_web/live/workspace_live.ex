defmodule BurrowWeb.WorkspaceLive do
  @moduledoc """
  A project's workspace, Burrow's home screen, laid out as the Peon UI kit's
  "4 · Peon: home" board: the project rail (every project the user can
  open), then the project bar, the chat tabs with the open chat and its
  changeset, and the preview. The preview switches between the chat's dev
  preview and what is live (staging and prod in a pipeline project), or
  gives way to "Deploys and usage".

  The project runs in a `Burrow.Cell`; until that is up it says it is
  starting. A project has up to four chats (`Burrow.Chats.max/0`), each with
  one change (its draft in the project's history); `Burrow.Activity` says
  where each stands. An empty chat starts its agent and preview with its
  first message.
  """

  use BurrowWeb, :live_view

  import BurrowWeb.WorkspaceLive.Components

  alias Burrow.{
    Accounts,
    Activity,
    Cell,
    Chat,
    Chats,
    Env,
    Incidents,
    Projects,
    Runs,
    Secrets,
    Ship,
    Teams
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    project = Projects.get!(scope, id)

    socket =
      assign(socket,
        page_title: project.name,
        burrow_project: project,
        base: ~p"/projects/#{project.id}",
        user: scope.user.email,
        theme: scope.user.theme,
        rail_open: scope.user.rail_open
      )

    if connected?(socket) do
      Accounts.opened_project(scope.user, project.id)
      Burrow.Activity.subscribe()
      Cell.subscribe()
    end

    case Cell.status(project.id) do
      :running -> {:ok, socket |> assign(ready: true) |> mount_project()}
      status -> {:ok, assign(socket, ready: false, cell: status)}
    end
  end

  defp mount_project(socket) do
    project = socket.assigns.burrow_project

    if connected?(socket) do
      Chats.subscribe(project.id)
      Ship.subscribe(project.id)
      Env.subscribe(project.id)
      Incidents.subscribe(project.id)
      Secrets.subscribe(project.id)
      for topic <- ["refs", "project"], do: Projects.subscribe(project.id, topic)
    end

    socket
    |> assign(project: project, repo?: Projects.Project.repo?(project))
    # The project rail and this project's sharing
    |> load_rail()
    |> assign(busy: if(connected?(socket), do: Chat.busy_ids(project.id), else: MapSet.new()))
    |> assign(chat: nil, tab: nil, info: nil, view: "dev")
    |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
    # Why the open chat stopped (Peon.Chat's {:stopped, reason}), while it is
    |> assign(stopped: nil)
    |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
    |> assign(draft: nil, form: to_form(%{"text" => ""}))
    # The "/" menu: the chat's commands and skills, and those matching the box
    |> assign(slash_items: [], slash: [])
    # "Deploys and usage" in place of the preview; one dialog at a time
    |> assign(overview: false, dialog: nil, new_project: new_project(), creating: false)
    |> assign(env_names: Env.names(project), live_only?: not Ship.staging?(project))
    |> assign(secrets: Secrets.list(project.id), secrets_key: 0)
    # Phones: one pane at a time
    |> assign(pane: "chat")
    |> assign(envs: Map.new(Env.names(project), &{&1, Env.info(project, &1)}))
    |> load_tabs()
    |> load_ship()
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{ready: false}} = socket), do: {:noreply, socket}

  def handle_params(%{"chat" => id}, _uri, socket) do
    case Chats.get(id) do
      nil ->
        {:noreply, push_patch(socket, to: socket.assigns.base)}

      chat ->
        project = socket.assigns.project
        if old = socket.assigns.chat, do: Chat.unsubscribe(project.id, old.id)
        if connected?(socket), do: Chat.subscribe(project.id, id)

        socket =
          socket
          |> assign(chat: chat, info: nil, start_error: nil, show_logs: false, pending: nil)
          |> assign(slash_items: [], slash: [], stopped: nil, starting: false, step: nil)
          |> select_tab()
          |> load_draft()
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
        {:noreply, push_patch(socket, to: chat_path(socket, first.chat.id), replace: true)}

      [] ->
        case Chats.create_empty(socket.assigns.project.id, socket.assigns.user) do
          {:ok, chat} ->
            {:noreply, push_patch(socket, to: chat_path(socket, chat.id), replace: true)}

          {:error, :full} ->
            {:noreply, socket}
        end
    end
  end

  defp start_chat(socket) do
    %{chat: %{id: id}, project: project} = socket.assigns

    socket
    |> assign(starting: true, stopped: nil, start_error: nil)
    |> start_async(:chat, fn -> Chat.ensure_started(project, id) end)
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
    case Chats.create_empty(socket.assigns.project.id, socket.assigns.user) do
      {:ok, chat} -> {:noreply, push_patch(socket, to: chat_path(socket, chat.id))}
      {:error, :full} -> {:noreply, put_flash(socket, :error, full_text())}
    end
  end

  # Closing a chat deletes it (Burrow.Chat.delete/2): its agent, preview and
  # workspace go; what it landed stays. Stopping a repo preview can take
  # minutes, so that runs on its own.
  def handle_event("close_chat", %{"id" => id}, socket) do
    project = socket.assigns.project

    with %{} = chat <- Chats.get(id),
         do:
           Task.Supervisor.start_child(Burrow.TaskSupervisor, fn -> Chat.delete(project, chat) end)

    {:noreply, socket}
  end

  def handle_event("toggle_rail", _params, socket) do
    open? = !socket.assigns.rail_open
    Accounts.put_rail_open(socket.assigns.current_scope.user, open?)
    {:noreply, assign(socket, rail_open: open?)}
  end

  # System, light, dark, round again; the user's, everywhere in Burrow.
  def handle_event("theme", _params, socket) do
    theme = %{"system" => "light", "light" => "dark"}[socket.assigns.theme] || "system"
    Accounts.put_theme(socket.assigns.current_scope.user, theme)
    {:noreply, assign(socket, theme: theme)}
  end

  def handle_event("keep_running", %{"hours" => hours}, socket) do
    chat = socket.assigns.chat

    case Integer.parse(hours) do
      {hours, ""} ->
        until = Chats.keep_running(chat, hours)
        socket = assign(socket, chat: %{chat | keep_until: until})
        {:noreply, if(socket.assigns.stopped, do: start_chat(socket), else: socket)}

      _ ->
        Chats.keep_running(chat, nil)
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

  def handle_event("revert", %{"id" => id}, socket) do
    case Ship.revert(socket.assigns.project, String.to_integer(id), socket.assigns.user) do
      {:ok, change} ->
        {:noreply, info(socket, "Taken out of main as ##{change.id}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not undo it: #{inspect(reason)}")}
    end
  end

  def handle_event("ship", %{"id" => id}, socket) do
    %{project: project, user: user} = socket.assigns

    case Ship.ship(project, String.to_integer(id), user) do
      :ok ->
        {:noreply, socket |> info("Shipping ##{id}.") |> assign(view: "prod")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not ship: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_auto_ship", _params, socket) do
    project = socket.assigns.project
    on? = Projects.settings(project)["auto_ship"] != true
    Projects.put_settings(project, %{"auto_ship" => on?, "auto_ship_by" => socket.assigns.user})
    {:noreply, load_ship(socket)}
  end

  def handle_event("restart_env", %{"env" => env}, socket) do
    Env.restart(socket.assigns.project, env)
    {:noreply, socket}
  end

  def handle_event("fix_incident", %{"id" => id}, socket) do
    case Incidents.fix(
           Incidents.get(String.to_integer(id)),
           socket.assigns.project,
           socket.assigns.user
         ) do
      {:ok, incident} -> {:noreply, push_patch(socket, to: chat_path(socket, incident.chat_id))}
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

    basic =
      if p.auth == "basic" and p.repo_url == "",
        do: %{"basic_username" => p.basic_username, "basic_password" => p.basic_password},
        else: %{}

    attrs =
      Map.merge(
        %{"name" => p.name, "repo_url" => p.repo_url, "team_id" => p.team_id, "auth" => p.auth},
        basic
      )

    cond do
      p.name == "" ->
        {:noreply, socket}

      true ->
        case Projects.create(socket.assigns.current_scope, attrs) do
          {:ok, project} ->
            {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}")}

          {:error, changeset} ->
            {:noreply,
             socket |> assign(new_project: p) |> put_flash(:error, first_error(changeset))}
        end
    end
  end

  def handle_event("share", %{"share" => %{"team_id" => team_id}}, socket) do
    %{current_scope: scope, burrow_project: project} = socket.assigns

    case Projects.share(scope, project, team_id) do
      {:ok, project} ->
        text = if project.team_id, do: "Shared.", else: "Only you can open it now."
        {:noreply, socket |> assign(dialog: nil) |> info(text) |> load_rail()}

      {:error, :not_owner} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can share it.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That isn't one of your teams.")}
    end
  end

  def handle_event("hand_over", %{"hand_over" => %{"user_id" => user_id}}, socket) do
    %{current_scope: scope, burrow_project: project} = socket.assigns

    case Projects.hand_over(scope, project, user_id) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> assign(dialog: nil)
         |> info("Handed over. Peon restarts on their AI login.")
         |> load_rail()}

      {:error, :not_owner} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can hand it over.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Hand it to someone in the team it is shared with.")}
    end
  end

  def handle_event("add_envs", _params, socket) do
    %{current_scope: scope, burrow_project: project} = socket.assigns

    case Projects.add_envs(scope, project) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> assign(dialog: nil)
         |> info("Staging is set up: main goes to staging, then you ship it to prod.")
         |> load_rail()}

      {:error, :not_owner} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can add staging.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("set_secret", %{"name" => name, "value" => value}, socket) do
    name = name |> String.trim() |> String.upcase()

    case Secrets.put(socket.assigns.project.id, name, String.trim(value), socket.assigns.user) do
      :ok ->
        {:noreply,
         socket
         |> update(:secrets_key, &(&1 + 1))
         |> info("#{name} is set. Previews and the live app restart to pick it up.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_secret", %{"name" => name}, socket) do
    Secrets.delete(socket.assigns.project.id, name)
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
      do: {:noreply, push_patch(socket, to: socket.assigns.base)},
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

  # A project or team changed, or what happens in a project.
  def handle_info(:rail_changed, %{assigns: %{ready: false}} = socket), do: {:noreply, socket}

  def handle_info(:rail_changed, socket) do
    %{current_scope: scope, burrow_project: project} = socket.assigns

    if Projects.visible?(scope, project.id),
      do:
        {:noreply,
         socket |> assign(burrow_project: Projects.get!(scope, project.id)) |> load_rail()},
      else: {:noreply, push_navigate(socket, to: ~p"/projects")}
  end

  # The project is up: open the workspace.
  def handle_info(
        {:cell, id, :running},
        %{assigns: %{ready: false, burrow_project: %{id: id}}} = socket
      ),
      do: {:noreply, push_navigate(socket, to: socket.assigns.base)}

  def handle_info(
        {:cell, id, status},
        %{assigns: %{ready: false, burrow_project: %{id: id}}} = socket
      ),
      do: {:noreply, assign(socket, cell: status)}

  def handle_info({:cell, _id, _status}, socket), do: {:noreply, socket}

  def handle_info({:env, name, info}, socket) do
    socket = update(socket, :envs, &Map.put(&1, name, info))
    # Stats arrive every few seconds; only reload the lists when something moved.
    if info.deploy || socket.assigns.overview,
      do: {:noreply, socket |> load_ship() |> load_tabs()},
      else: {:noreply, socket}
  end

  def handle_info({:incident, _}, socket), do: {:noreply, load_ship(socket)}

  def handle_info({:secrets, secrets}, socket), do: {:noreply, assign(socket, secrets: secrets)}

  def handle_info({:check_step, id, step, status}, socket) do
    if socket.assigns.chat && socket.assigns.chat.id == id,
      do: {:noreply, socket |> assign(step: {step, status}) |> load_draft()},
      else: {:noreply, socket}
  end

  def handle_info(:clear_info, socket), do: {:noreply, clear_flash(socket, :info)}

  # Drafts checked or landed, main checked, refs moved, settings changed.
  def handle_info(_msg, socket),
    do: {:noreply, socket |> load_draft() |> load_tabs() |> load_ship()}

  # Info flashes clear themselves so they don't cover the work; errors stay.
  defp info(socket, text) do
    Process.send_after(self(), :clear_info, 4_000)
    put_flash(socket, :info, text)
  end

  defp full_text, do: "Up to #{Chats.max()} chats. Close one first."

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
    case Chat.send_message(socket.assigns.project, socket.assigns.chat.id, text) do
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
    do: assign(socket, logs: Env.logs(socket.assigns.project, env))

  defp load_logs(socket), do: socket

  # Every project the user can open, with what it is doing
  # (`Burrow.Activity`), and this project's sharing.
  defp load_rail(socket) do
    %{current_scope: scope, burrow_project: project} = socket.assigns

    rail =
      for p <- Projects.list(scope) do
        tile = Activity.of(p)

        %{
          id: p.id,
          name: p.name,
          url: ~p"/projects/#{p.id}",
          current: p.id == project.id,
          state: tile["state"],
          label: tile["label"],
          pct: tile["pct"]
        }
      end

    sharing = %{
      owner?: Projects.owner?(scope, project),
      live_only?: Burrow.Projects.Project.live_only?(project),
      team: project.team && %{id: project.team.id, name: project.team.name},
      teams: for(t <- Teams.list(scope), do: %{id: t.id, name: t.name}),
      teammates: teammates(project)
    }

    assign(socket, rail: rail, sharing: sharing)
  end

  defp teammates(%{team: %Teams.Team{} = team, user_id: owner_id}),
    do:
      for(
        m <- Teams.members(team),
        m.user_id != owner_id,
        do: %{id: m.user.id, email: m.user.email}
      )

  defp teammates(_project), do: []

  defp chat_path(socket, id), do: socket.assigns.base <> "/c/" <> id

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, &BurrowWeb.CoreComponents.translate_error/1)
         |> Enum.at(0) do
      {field, [message | _]} -> "#{Phoenix.Naming.humanize(field)} #{message}"
      _ -> "Could not create the project."
    end
  end

  # The chat tabs, each with its draft and phase (Burrow.Activity).
  defp load_tabs(socket),
    do:
      socket
      |> assign(tabs: Activity.chats(socket.assigns.project, socket.assigns.busy))
      |> select_tab()

  defp select_tab(%{assigns: %{chat: nil}} = socket), do: assign(socket, tab: nil)

  defp select_tab(socket) do
    id = socket.assigns.chat.id
    assign(socket, tab: Enum.find(socket.assigns.tabs, &(&1.chat.id == id)))
  end

  defp load_draft(%{assigns: %{chat: nil}} = socket), do: socket
  defp load_draft(%{assigns: %{repo?: true}} = socket), do: socket

  defp load_draft(socket) do
    repo = Projects.repo_dir(socket.assigns.project)
    assign(socket, draft: Totem.Repo.draft(repo, socket.assigns.chat.id))
  end

  defp load_ship(%{assigns: %{repo?: true}} = socket),
    do:
      assign(socket,
        incidents: [],
        main_check: nil,
        shippable: nil,
        auto_ship: false,
        nothing_built?: false,
        deploys: []
      )

  defp load_ship(socket) do
    project = socket.assigns.project

    socket =
      assign(socket,
        incidents: Incidents.list(project.id),
        main_check: Ship.main_check(project),
        shippable: Activity.shippable(project),
        auto_ship: Projects.settings(project)["auto_ship"] == true,
        nothing_built?: Totem.Repo.ref(Projects.repo_dir(project), "prod") == nil
      )

    if socket.assigns.overview,
      do: assign(socket, deploys: deploys(project)),
      else: assign(socket, deploys: [])
  end

  # The latest healthy deploys, one row per change, with where it is now.
  defp deploys(project) do
    repo = Projects.repo_dir(project)
    names = Env.names(project)

    project.id
    |> Runs.list("deploy", nil, 30)
    |> Enum.filter(&(&1.status == "healthy"))
    |> Enum.uniq_by(& &1.change_id)
    |> Enum.take(8)
    |> Enum.map(fn run ->
      where = Enum.find(Enum.reverse(names), &Totem.Repo.contains?(repo, &1, run.change_id))
      change = Totem.Repo.change(repo, run.change_id)

      %{
        id: run.change_id,
        intent: (change && change.intent) || "",
        where: where,
        at: run.inserted_at
      }
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
  def render(%{ready: false} = assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-col items-center gap-3 text-center" role="status">
        <.icon
          :if={!match?({:exited, _}, @cell)}
          name="hero-arrow-path"
          class="size-8 animate-spin text-[var(--accent-text)]"
        />
        <h1 class="m-0 text-xl font-semibold">
          {if match?({:exited, _}, @cell),
            do: "#{@burrow_project.name} stopped",
            else: "Starting #{@burrow_project.name}…"}
        </h1>
        <p class="m-0 text-[var(--text-2)]">
          {if match?({:exited, _}, @cell),
            do: "It stopped and is restarting. This page opens it once it is back.",
            else: "Its workspace opens as soon as it is up."}
        </p>
        <.link navigate={~p"/projects"} class="xlink">All projects</.link>
      </div>
    </Layouts.auth>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        view: effective_view(assigns),
        dev?: dev?(assigns),
        promote: assigns.shippable,
        open_incidents: Enum.count(assigns.incidents, &(&1.status != "resolved"))
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
      <.rail rail={@rail} open={@rail_open} theme={@theme} />
      <div id="theme" phx-hook=".Theme" data-theme={@theme} hidden></div>

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
          preview={@preview}
          view={@view}
          agent?={@info != nil}
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
              base={@base}
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
              <div :if={@main_check && @main_check.status == "failed"} class="notice err">
                <span>Main #{@main_check.change_id} did not pass in prod mode.</span>
              </div>
              <.connect_card
                :if={@chat && asked(@secrets, @chat.id) != []}
                secrets={asked(@secrets, @chat.id)}
                key={@secrets_key}
              />
              <.change_card
                :if={@draft}
                draft={@draft}
                tab={@tab}
                step={@step}
                live_only?={@live_only?}
                promote={@promote}
                main_check={@main_check}
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
                  placeholder={placeholder(@tab)}
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
              auto_promote={@auto_ship}
              incidents={@incidents}
              deploys={@deploys}
              base={@base}
            />
            <.preview_pane
              :if={!@overview}
              preview={@preview}
              view={@view}
              env_names={@env_names}
              live_only?={@live_only?}
              dev?={@dev?}
              number={@draft && @draft.change}
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

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Theme">
      // The user's theme on <html>; Burrow keeps it for the next page load.
      export default {
        mounted() { this.apply() },
        updated() { this.apply() },
        apply() { document.documentElement.dataset.theme = this.el.dataset.theme }
      }
    </script>
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

  # "watchtower · live #8 · no staging · shared with Ops"
  defp meta(%{project: nil}), do: ""

  defp meta(assigns) do
    %{project: project, envs: envs, sharing: sharing} = assigns
    tag = fn env -> with(%{deployed: id} when id != nil <- envs[env], do: "##{id}") || "—" end

    parts =
      cond do
        assigns.repo? -> [project.slug, "from #{repo_name(project)}"]
        assigns.nothing_built? -> [project.slug, "nothing built yet"]
        assigns.live_only? -> [project.slug, "live #{tag.("prod")}", "no staging"]
        true -> [project.slug, "staging #{tag.("staging")}", "prod #{tag.("prod")}"]
      end

    shared = if sharing && sharing.team, do: ["shared with #{sharing.team.name}"], else: []
    Enum.join(parts ++ shared, " · ")
  end

  defp repo_name(project),
    do:
      (URI.parse(project.repo_url).path || "")
      |> String.trim_leading("/")
      |> String.trim_trailing(".git")

  defp hello(project, true), do: "What should #{project && project.name} do?"
  defp hello(project, false), do: "What should change in #{project && project.name}?"

  defp placeholder(%{phase: phase}) when phase in ~w(landing staged live),
    do: "On main. Start a new chat for the next change."

  defp placeholder(%{phase: "new"}), do: "Describe the change"
  defp placeholder(_tab), do: "Message Peon (/ for commands)"

  # The line under the thread once the chat's change is on main.
  defp event_line(%{phase: "landing", draft: %{change: id}}, _live_only?),
    do: %{text: "##{id} on main · ready to ship", tone: nil}

  defp event_line(%{phase: "staged", draft: %{change: id}}, _live_only?),
    do: %{text: "##{id} on main · on staging", tone: "ok"}

  defp event_line(%{phase: "live", draft: %{change: id}}, true),
    do: %{text: "##{id} on main · live", tone: "ok"}

  defp event_line(%{phase: "live", draft: %{change: id}}, false),
    do: %{text: "##{id} shipped to prod", tone: "ok"}

  defp event_line(_tab, _live_only?), do: nil

  # What the preview pane shows: the chat's dev preview, or staging or prod.
  defp preview(%{view: "dev", info: nil, starting: starting, stopped: stopped} = assigns) do
    %{
      url: nil,
      status: if(starting, do: :starting),
      ref: number(assigns.draft),
      live?: false,
      message: if(stopped, do: stopped_message(stopped), else: "Starting the preview…"),
      wake: stopped != nil and not starting
    }
  end

  defp preview(%{view: "dev", info: info, draft: draft, stopped: stopped}) do
    %{
      links: info[:preview_links] || [],
      pr: info[:pr_url],
      url: info.preview_url,
      status: info.preview_status,
      ref: number(draft),
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

  defp number(%{change: id}) when id != nil, do: "##{id}"
  defp number(_draft), do: nil

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
  defp activity({"peon_submit_changeset", _}), do: "Checking and handing in the change…"
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
      "Stopped to make room: at most #{Application.get_env(:burrow, :max_running_chats, 4)} chats run at once. Send a message or start it again."

  defp stopped_message(_),
    do: "The agent and preview stopped. Send a message or start them again."

  defp env_message(name, %{status: :running, deployed: id}),
    do:
      "#{String.capitalize(name)} runs ##{id} with its real security headers, so it opens in its own tab."

  defp env_message(name, %{deploy: %{target: id}}) when id != nil,
    do: "Deploying ##{id} to #{name}…"

  defp env_message(name, info), do: "#{String.capitalize(name)}: #{env_text(info)}"
end
