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

  The preview's "design" view shows the chat's boards (`Burrow.Design`,
  `BurrowWeb.WorkspaceLive.Design`): what the agent draws in `design/`, as
  it draws it.
  """

  use BurrowWeb, :live_view

  import BurrowWeb.WorkspaceLive.Components
  import BurrowWeb.WorkspaceLive.Design

  alias Burrow.{
    Accounts,
    Activity,
    Cell,
    Chat,
    Chats,
    Design,
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
    # The change the open chat follows up on (`followed/2`)
    |> assign(followed: nil)
    # The design view: the chat's boards, the one open full size (maybe next
    # to the dev preview), boards whose scripts failed ({hash, error} by
    # path), and what the chat changed (Burrow.Design.pending/2)
    |> assign(boards: [], board: nil, side: false, board_errors: %{}, design_url: nil)
    |> assign(design_pending: :none)
    |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
    # Why the open chat stopped (Peon.Chat's {:stopped, reason}), while it is
    |> assign(stopped: nil)
    |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
    |> assign(draft: nil, form: to_form(%{"text" => ""}))
    # The owner's models and their thinking levels, for the chat box
    |> assign(models: %{}, default_model: Burrow.OpenCode.model(project.user_id))
    |> then(fn socket ->
      if connected?(socket),
        do: start_async(socket, :models, fn -> Burrow.OpenCode.models(project.user_id) end),
        else: socket
    end)
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
          |> assign(board: nil, side: false, board_errors: %{}, design_pending: :none)
          |> assign(design_url: BurrowWeb.DesignController.path(project.id, chat.id))
          |> assign(followed: followed(project, chat))
          |> select_tab()
          |> load_draft()
          |> load_boards()
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

  def handle_async(:models, {:ok, {:ok, models}}, socket) do
    default = Burrow.OpenCode.usable(socket.assigns.default_model, Enum.map(models, &elem(&1, 0)))
    {:noreply, assign(socket, models: Map.new(models), default_model: default)}
  end

  def handle_async(:models, _result, socket), do: {:noreply, socket}

  def handle_async(:design_pending, {:ok, {id, pending}}, socket) do
    if socket.assigns.chat && socket.assigns.chat.id == id,
      do: {:noreply, assign(socket, design_pending: pending)},
      else: {:noreply, socket}
  end

  def handle_async(:design_pending, _result, socket), do: {:noreply, socket}

  @impl true
  # A disabled chat box sends no text.
  def handle_event("send", params, socket) do
    text = String.trim(params["text"] || "")
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

  def handle_event("typing", params, socket),
    do: {:noreply, slash_menu(socket, params["text"] || "")}

  # Each box sends only itself: the model, or the thinking level. A level
  # the (newly picked) model lacks goes back to its default.
  def handle_event("pick_model", params, socket) do
    %{chat: chat, models: models, default_model: default} = socket.assigns
    model = Map.get(params, "model", chat.model)
    effort = Map.get(params, "effort", chat.effort)
    effort = if effort in Map.get(models, model || default, []), do: effort
    Chats.pick_model(chat, model, effort)
    {:noreply, assign(socket, chat: Chats.get(chat.id))}
  end

  def handle_event("wake", _params, socket), do: {:noreply, start_chat(socket)}

  def handle_event("new_chat", _params, socket), do: {:noreply, new_chat(socket, [])}

  # A new chat that goes on from the open chat's change (Burrow.Agent.Prompt).
  def handle_event("follow_up", _params, socket) do
    case socket.assigns.draft do
      %{change: id} when id != nil -> {:noreply, new_chat(socket, follows: id)}
      _ -> {:noreply, socket}
    end
  end

  # The chip on a follow-up's chat box: it starts from scratch instead.
  def handle_event("unfollow", _params, socket) do
    %{chat: chat} = socket.assigns
    Chats.set(chat, follows: nil)
    {:noreply, socket |> assign(chat: %{chat | follows: nil}, followed: nil) |> load_tabs()}
  end

  # Closing a chat deletes it (Burrow.Chat.delete/2): its agent, preview and
  # workspace go; what it landed stays. Stopping a repo preview can take
  # minutes, so that runs on its own. Closing the open chat opens the one
  # before it, else a new one.
  def handle_event("close_chat", %{"id" => id}, socket) do
    project = socket.assigns.project

    with %{} = chat <- Chats.get(id),
         do:
           Task.Supervisor.start_child(Burrow.TaskSupervisor, fn -> Chat.delete(project, chat) end)

    if socket.assigns.chat && socket.assigns.chat.id == id,
      do: {:noreply, leave_chat(socket, id)},
      else: {:noreply, socket}
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
    {:noreply, socket |> assign(slash: []) |> put_in_box("/#{name} ")}
  end

  # The design view: a board full size, the next in its folder, back.
  def handle_event("open_board", %{"path" => path}, socket),
    do: {:noreply, assign(socket, board: path, side: false)}

  def handle_event("close_board", _params, socket),
    do: {:noreply, assign(socket, board: nil, side: false)}

  def handle_event("board_step", %{"by" => by}, socket),
    do: {:noreply, step_board(socket, String.to_integer(by))}

  def handle_event("board_key", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, step_board(socket, -1)}

  def handle_event("board_key", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, step_board(socket, 1)}

  def handle_event("board_key", %{"key" => "Escape"}, socket),
    do: {:noreply, assign(socket, board: nil, side: false)}

  def handle_event("board_key", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_side", _params, socket), do: {:noreply, update(socket, :side, &(!&1))}

  def handle_event("board_error", %{"path" => path, "hash" => hash, "error" => error}, socket),
    do: {:noreply, update(socket, :board_errors, &Map.put(&1, path, {hash, error}))}

  # Words for the chat box, for the user to send or change.
  def handle_event("build_board", %{"path" => path}, socket),
    do: {:noreply, put_in_box(socket, "Build #{path}")}

  def handle_event("fix_board", %{"path" => path}, socket) do
    error =
      case socket.assigns.board_errors[path] do
        {_hash, error} -> " (#{error})"
        nil -> ""
      end

    {:noreply, put_in_box(socket, "#{path} does not load#{error}. Fix it.")}
  end

  def handle_event("ask", %{"text" => text}, socket), do: {:noreply, put_in_box(socket, text)}

  def handle_event("submit_design", _params, socket) do
    %{project: project, chat: chat, user: user} = socket.assigns

    case Ship.submit_design(project, chat.id, user) do
      {:ok, change} ->
        {:noreply,
         socket
         |> info("The boards are on main as ##{change.id}.")
         |> load_draft()
         |> load_tabs()
         |> load_boards()}

      {:error, {:conflict, paths}} ->
        {:noreply,
         put_flash(socket, :error, "Another chat changed #{Enum.join(paths, ", ")} too.")}

      {:error, :not_design_only} ->
        {:noreply, put_flash(socket, :error, "This chat changed more than boards.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not submit: #{inspect(reason)}")}
    end
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
        %{
          "name" => p.name,
          "repo_url" => p.repo_url,
          "github_token" => p.github_token,
          "team_id" => p.team_id,
          "auth" => p.auth
        },
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

  def handle_event("view", %{"view" => "design"}, socket),
    do: {:noreply, socket |> assign(view: "design", overview: false) |> load_boards()}

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
    do: {:noreply, socket |> update_info(messages: messages) |> load_boards()}

  def handle_info({:status, status}, socket) do
    was = socket.assigns.info && socket.assigns.info.preview_status
    busy? = socket.assigns.info && socket.assigns.info.busy?
    socket = update_info(socket, status)
    # A turn is over: what it drew, and whether that is all the chat changed.
    socket = if busy? && !status.busy?, do: load_boards(socket), else: socket

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
    do: {:noreply, socket |> load_draft() |> load_tabs() |> load_ship() |> load_boards()}

  # Info flashes clear themselves so they don't cover the work; errors stay.
  defp info(socket, text) do
    Process.send_after(self(), :clear_info, 4_000)
    put_flash(socket, :info, text)
  end

  defp full_text, do: "Up to #{Chats.max()} chats. Close one first."

  # A new empty chat with the open chat's model, its box ready to type in.
  defp new_chat(socket, opts) do
    %{project: project, user: user, chat: chat} = socket.assigns
    picked = if chat, do: [model: chat.model, effort: chat.effort], else: []

    case Chats.create_empty(project.id, user, picked ++ opts) do
      {:ok, chat} ->
        socket |> push_patch(to: chat_path(socket, chat.id)) |> push_event("composer:focus", %{})

      {:error, :full} ->
        put_flash(socket, :error, full_text())
    end
  end

  defp leave_chat(socket, id) do
    tabs = Enum.map(socket.assigns.tabs, & &1.chat.id)

    case Enum.find_index(tabs, &(&1 == id)) do
      nil ->
        socket

      i ->
        case Enum.at(tabs, if(i > 0, do: i - 1, else: 1)) do
          nil -> new_chat(socket, [])
          other -> push_patch(socket, to: chat_path(socket, other))
        end
    end
  end

  # "Follow up on #N": change N, while the chat is empty.
  defp followed(_project, %{follows: nil}), do: nil
  defp followed(_project, %{started_at: started}) when started != nil, do: nil

  defp followed(project, %{follows: id}) do
    if !Projects.Project.repo?(project),
      do: Totem.Repo.change(Projects.repo_dir(project), id)
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

  defp put_in_box(socket, text), do: push_event(socket, "composer:put", %{text: text})

  # The open board's neighbour in its folder, `by` along.
  defp step_board(%{assigns: %{board: nil}} = socket, _by), do: socket

  defp step_board(socket, by) do
    %{boards: boards, board: path} = socket.assigns
    folder = Enum.find_value(boards, &(&1.path == path && &1.folder))
    siblings = Enum.filter(boards, &(&1.folder == folder))

    case Enum.find_index(siblings, &(&1.path == path)) do
      nil -> socket
      i when i + by < 0 -> socket
      i -> assign(socket, board: (Enum.at(siblings, i + by) || Enum.at(siblings, i)).path)
    end
  end

  # The chat's boards; when it isn't working, whether boards are all it
  # changed (a walk over its checkout, so in the background).
  defp load_boards(%{assigns: %{chat: nil}} = socket), do: socket
  defp load_boards(%{assigns: %{repo?: true}} = socket), do: socket

  defp load_boards(socket) do
    %{project: project, chat: %{id: id}, info: info} = socket.assigns
    boards = Design.boards(project, id)
    socket = assign(socket, boards: boards)

    cond do
      not connected?(socket) or (info && info.busy?) ->
        socket

      Enum.any?(boards, & &1.here?) ->
        start_async(socket, :design_pending, fn -> {id, Design.pending(project, id)} end)

      true ->
        assign(socket, design_pending: :none)
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

  # The chat's dev preview while it has one; else what is live. The design
  # view stays.
  defp default_view(%{assigns: %{view: "design"}} = socket), do: socket

  defp default_view(socket) do
    if dev?(socket.assigns), do: assign(socket, view: "dev"), else: assign(socket, view: "prod")
  end

  # The dev preview stays until the chat's change is live, to look into it
  # while it waits on main or staging (`Burrow.Chat` keeps it running).
  defp dev?(%{chat: chat, tab: tab}),
    do: chat != nil and chat.started_at != nil and not match?(%{phase: "live"}, tab)

  defp closed?(%{phase: phase}), do: phase in ~w(landing staged live)
  defp closed?(_tab), do: false

  defp new_project do
    %{
      name: "",
      repo_url: "",
      github_token: "",
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
    {"github_token", :github_token},
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

    drawing = drawing(assigns)

    assigns =
      assign(assigns,
        preview: preview(assigns),
        drawing: drawing,
        design: design_switch(assigns, drawing),
        board_card: board_card(assigns, drawing),
        preview_dev: preview_dev(assigns),
        follows: assigns.chat && assigns.chat.started_at == nil && assigns.followed
      )

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
              live_only?={@live_only?}
            />

            <div class="ws-scroll" id="messages" phx-hook=".ScrollBottom">
              <div class="ws-thread">
                <div :if={(@chat && @chat.started_at == nil) and @pending == nil} class="ws-hello">
                  <Layouts.mark size={52} />
                  <h2>
                    {if @follows,
                      do: "What should change next?",
                      else: hello(@project, @nothing_built?)}
                  </h2>
                  <p :if={@follows} class="muted">
                    Peon starts from #{@follows.id}: its summary and the files it touched.
                  </p>
                </div>
                <div :if={@starting} class="ws-working" role="status">
                  <.icon name="hero-arrow-path" class="size-4 spin" /> Starting the agent and preview…
                </div>
                <div :if={@start_error} class="say-error">{@start_error}</div>
                <%= for block <- blocks((@info && @info.messages) || []) do %>
                  <.block block={block} />
                <% end %>
                <div :if={@pending} class="bubble-user opacity-60">{@pending}</div>
                <.peon_at_work
                  :if={@info && @info.busy?}
                  job={job(@info.messages)}
                  stage={stage(@info.messages)}
                />
                <div :if={@info && @info.busy?} class="ws-working" role="status">
                  <span class="font-medium shrink-0">{peon_says(@info.messages)}</span>
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
              <.design_card :if={@board_card} card={@board_card} live_only?={@live_only?} />
              <.change_card
                :if={@draft && !Design.only?(@draft.files)}
                draft={@draft}
                tab={@tab}
                step={@step}
                live_only?={@live_only?}
                promote={@promote}
                main_check={@main_check}
              />
              <.chat_done
                :if={finished?(@tab, @live_only?)}
                tab={@tab}
                full?={length(@tabs) >= Chats.max()}
                attach?={@info != nil}
              />
              <pre :if={finished?(@tab, @live_only?) && @info && @show_attach} class="out mono">{@info.attach}</pre>
              <.form
                :if={!finished?(@tab, @live_only?)}
                for={@form}
                id="composer"
                phx-submit="send"
                phx-change="typing"
                class="composer"
              >
                <span :if={@follows} class="ctx">
                  <span>↳ follows #{@follows.id} · {@follows.intent}</span>
                  <button
                    type="button"
                    class="cx"
                    phx-click="unfollow"
                    aria-label={"Don't follow up on ##{@follows.id}"}
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </span>
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
                  placeholder={placeholder(@tab, @follows)}
                >{@form[:text].value}</textarea>
                <div class="cbar">
                  <.model_pick
                    :if={@chat && !closed?(@tab)}
                    chat={@chat}
                    models={@models}
                    default={@default_model}
                  />
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
              design={@design}
            >
              <.design_pane
                boards={@boards}
                open={@board}
                side={@side}
                drawing={@drawing}
                errors={@board_errors}
                url={@design_url}
                dev={@preview_dev}
              />
            </.preview_pane>
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
          this.handleEvent("composer:focus", () => this.el.focus())
          this.handleEvent("composer:put", ({text}) => {
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

  # The board the agent draws right now: what its latest tool call writes.
  defp drawing(%{info: %{busy?: true, messages: messages}}) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role != :user))
    |> Enum.find(&(&1.role == :tool))
    |> case do
      %{text: text} -> text |> Design.drawn() |> List.last()
      nil -> nil
    end
  end

  defp drawing(_assigns), do: nil

  # The chat's dev preview while it runs, to set next to a board.
  defp preview_dev(%{info: %{preview_status: :running, preview_url: url}, draft: draft} = assigns)
       when url != nil,
       do: if(dev?(assigns), do: %{url: url, name: String.trim("dev #{number(draft)}")})

  defp preview_dev(_assigns), do: nil

  # The design view's switch, in a project with its own app.
  defp design_switch(%{repo?: true}, _drawing), do: nil

  defp design_switch(assigns, drawing) do
    count = Enum.count(assigns.boards, & &1.here?)

    note =
      cond do
        drawing -> "Peon is drawing #{Path.basename(drawing)}"
        count > 0 -> "design/ · #{count} changed in this chat"
        true -> "design/"
      end

    %{count: count, drawing: drawing != nil, note: note}
  end

  # The card of a change that is boards alone (Burrow.Design), else nil:
  # drawing them, ready to submit, or on main.
  defp board_card(%{repo?: true}, _drawing), do: nil
  defp board_card(%{chat: nil}, _drawing), do: nil

  defp board_card(assigns, drawing) do
    %{draft: draft, boards: boards, design_pending: pending, info: info} = assigns
    here? = drawing != nil or Enum.any?(boards, & &1.here?)
    busy? = info != nil and info.busy?
    design? = match?({:design, _}, pending)
    landed = draft && draft.status == "landed" && Design.only?(draft.files) && draft.change

    cond do
      draft && (draft.status != "landed" or not Design.only?(draft.files)) -> nil
      here? and busy? and (drawing != nil or design?) -> %{state: :drawing, change: nil}
      here? and design? and not busy? -> %{state: :ready, change: nil}
      here? and pending == :code -> nil
      landed -> %{state: :landed, change: landed}
      true -> nil
    end
  end

  # A view that isn't there falls back to what is live.
  defp effective_view(%{view: "dev"} = assigns), do: if(dev?(assigns), do: "dev", else: "prod")
  defp effective_view(%{view: "design", repo?: true}), do: "prod"

  defp effective_view(%{view: "staging", env_names: names}),
    do: if("staging" in names, do: "staging", else: "prod")

  defp effective_view(%{view: view}), do: view

  # "watchtower · live #8 · no staging · shared with Ops"
  defp meta(%{project: nil}), do: ""

  defp meta(assigns) do
    %{project: project, envs: envs, sharing: sharing} = assigns
    # Nothing deployed yet (or the env is down): a dash.
    tag = fn env ->
      case envs[env] do
        %{deployed: id} when id != nil -> "##{id}"
        _ -> "—"
      end
    end

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

  defp placeholder(%{phase: phase}, _follows) when phase in ~w(landing staged live),
    do: "On main. Start a new chat for the next change."

  defp placeholder(_tab, %{}), do: "What should change next?"
  defp placeholder(%{phase: "new"}, _follows), do: "Describe the change"
  defp placeholder(_tab, _follows), do: "Message Peon (/ for commands)"

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

  # The tool calls of the turn so far, latest first.
  defp turn_tools(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role != :user))
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(&split_tool(&1.text))
  end

  # What the peon is on right now, in plain words, from its latest tool call.
  defp doing(messages) do
    case turn_tools(messages) do
      [] -> "Thinking it over…"
      [tool | _] -> activity(tool)
    end
  end

  # Which peon in the camp works, from the latest tool call; none naps.
  defp job(messages) do
    case turn_tools(messages) do
      [] -> nil
      [tool | _] -> tool_job(tool)
    end
  end

  # How far the camp's hut is: a step per change to the code this turn.
  defp stage(messages),
    do: messages |> turn_tools() |> Enum.count(&(tool_job(&1) == "build")) |> min(5)

  defp tool_job({"bash", command}) do
    cond do
      command =~ "mix test" -> "test"
      command =~ ~r/deps\.get|npm (install|ci)/ -> "wood"
      command =~ ~r/mix (compile|format)/ -> "build"
      true -> "mine"
    end
  end

  defp tool_job({tool, _}) when tool in ~w(edit write patch apply_patch multiedit), do: "build"
  defp tool_job({"peon_submit_changeset", _}), do: "merge"
  defp tool_job({"todowrite", _}), do: nil
  defp tool_job(_), do: "mine"

  # What the peon says while it works, as in Warcraft III; a new line as the
  # turn goes on.
  @peon_says ["Work, work.", "Zug zug.", "Okie dokie.", "Be happy to.", "Dabu.", "Me busy."]
  defp peon_says(messages), do: Enum.at(@peon_says, rem(length(messages), length(@peon_says)))

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

  defp activity({tool, path}) when tool in ~w(edit write patch apply_patch multiedit) do
    case Design.drawn("#{tool} #{path}") do
      [] ->
        "Changing #{path |> String.split(" ") |> Enum.map_join(", ", &Path.basename/1)}…"

      boards ->
        "Drawing #{Enum.map_join(boards, ", ", &String.replace_prefix(&1, "design/", ""))}…"
    end
  end

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
