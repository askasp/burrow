defmodule BurrowWeb.WorkspaceLive do
  @moduledoc """
  A project's workspace, Burrow's home screen, laid out as the Peon UI kit's
  "4 · Peon: chats in a drawer" board: the chat drawer (the project
  switcher on top, then the project's chats), the bar with the open chat,
  the chat and its changeset, and the preview. The preview switches between
  the chat's dev preview and staging (an internal app's live: dev, then
  live, `Projects.Project.internal?/1`), or gives way to "Deploys and usage".

  The project runs in a `Burrow.Cell`; until that is up it says it is
  starting. Everyone sees only their own chats in it (`Burrow.Chats.list/2`),
  each with one change (its draft in the project's history);
  `Burrow.Activity` says where each stands. A chat whose change is out is
  done and stays in the drawer. An empty chat starts its agent and preview
  with its first message.

  The preview's "design" view shows the chat's boards (`Burrow.Design`,
  `BurrowWeb.WorkspaceLive.Design`): what the agent draws in `design/`, as
  it draws it.
  """

  use BurrowWeb, :live_view

  import BurrowWeb.WorkspaceLive.Components
  import BurrowWeb.WorkspaceLive.Horde
  import BurrowWeb.WorkspaceLive.Design

  alias Burrow.{
    Accounts,
    Activity,
    Cell,
    Chat,
    Chats,
    Hordes,
    Design,
    Env,
    Incidents,
    Projects,
    Runs,
    Secrets,
    Ship,
    Teams
  }

  alias BurrowWeb.Peek

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    project = Projects.get!(scope, id)

    socket =
      assign(socket,
        page_title: project.name,
        burrow_project: project,
        base: ~p"/projects/#{project.id}",
        user: scope.user.email,
        theme: scope.user.theme,
        folded_days: scope.user.folded_days,
        # Another place whose chats the drawer lists (BurrowWeb.Peek)
        peek: nil,
        # Where a project still starting opens once it is up: the chat asked
        # for (or /c/new), else the one worked on last
        after_start:
          cond do
            params["chat"] -> ~p"/projects/#{project.id}/c/#{params["chat"]}"
            params["open"] -> ~p"/projects/#{project.id}?open=#{params["open"]}"
            true -> ~p"/projects/#{project.id}"
          end
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
      # A project whose cell started before these existed gets them now.
      if Hordes.going(project.id) != [], do: Hordes.Runner.ensure(project)
      if Projects.Project.repo?(project), do: Burrow.GitRepo.Merged.ensure(project)
      Chats.subscribe(project.id)
      Hordes.subscribe(project.id)
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
    # The open chat's horde (`Burrow.Hordes`), the peon looked into (its n), its
    # last failed check and its chat's model; what the horde shipped, when
    # looked at; the errors it paused on; or the horde the open chat is a peon of
    |> assign(horde: nil, peon: nil, peon_failure: nil, peon_model: nil, peon_of: nil)
    |> assign(horde_changes: nil, horde_errors: [])
    # The change the open chat follows up on (`followed/2`), the general
    # chat it starts from (`from_chat/1`)
    |> assign(followed: nil, from: nil)
    # The design view: the chat's boards, the one open full size (maybe next
    # to the dev preview), boards whose scripts failed ({hash, error} by
    # path), and what the chat changed (Burrow.Design.pending/2)
    |> assign(boards: [], board: nil, side: false, board_errors: %{}, design_url: nil)
    |> assign(picked: MapSet.new())
    |> assign(design_pending: :none)
    |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
    # Why the open chat stopped (Peon.Chat's {:stopped, reason}), while it is
    |> assign(stopped: nil)
    |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
    |> assign(draft: nil, form: to_form(%{"text" => ""}))
    # The open chat's queue (Burrow.Tickets), where its images are, and the
    # images going with the message that starts it
    |> assign(tickets: [], images_url: nil, pending_images: [])
    |> allow_upload(:images,
      accept: ~w(.png .jpg .jpeg .gif .webp),
      max_entries: 4,
      max_file_size: 10_000_000
    )
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
    |> assign(env_names: Env.names(project), landing: Env.landing(project))
    |> assign(secrets: Secrets.list(project.id), secrets_key: 0)
    # Phones: one pane at a time; wide screens can put the preview away, or
    # show the app in it phone-sized
    |> assign(pane: "chat", preview_open: true, phone: false)
    |> assign(envs: Map.new(Env.names(project), &{&1, Env.info(project, &1)}))
    |> load_tabs()
    |> load_ship()
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{ready: false}} = socket), do: {:noreply, socket}

  # /c/new, from the drawer on another page: an empty chat, as New chat gives.
  def handle_params(%{"chat" => "new"}, _uri, socket), do: {:noreply, new_chat(socket, [])}

  def handle_params(%{"chat" => id} = params, _uri, socket) do
    case Chats.get(socket.assigns.project, socket.assigns.current_scope.user.id, id) do
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
          |> assign(picked: MapSet.new())
          |> assign(design_url: BurrowWeb.DesignController.path(project.id, chat.id))
          |> assign(images_url: BurrowWeb.ChatImageController.path(project.id, chat.id))
          |> assign(tickets: Chat.tickets(project, chat.id), pending_images: [])
          |> assign(followed: followed(project, chat), from: from_chat(chat))
          |> assign(peon: nil, peon_failure: nil, horde_changes: nil)
          |> load_horde()
          |> select_tab()
          |> load_draft()
          |> load_boards()
          |> default_view()
          |> open(params["open"])

        # An empty chat starts its agent with its first message.
        if connected?(socket) and chat.started_at,
          do: {:noreply, start_chat(socket)},
          else: {:noreply, socket}
    end
  end

  # The workspace opens on the chat worked on last, or a new empty one.
  def handle_params(params, _uri, socket) do
    id =
      case drawer_tabs(socket.assigns.tabs) do
        [first | _] -> first.chat.id
        [] -> Chats.create_empty(socket.assigns.project.id, socket.assigns.current_scope.user).id
      end

    # The projects page's menu opens "Deploys and usage" or Secrets here (`?open=`).
    query = if params["open"], do: "?open=" <> URI.encode_www_form(params["open"]), else: ""
    {:noreply, push_patch(socket, to: chat_path(socket, id) <> query, replace: true)}
  end

  # The project menu's "Deploys and usage" and Secrets, also from `?open=`.
  defp open(socket, "deploys"), do: socket |> assign(overview: true) |> load_ship()
  defp open(socket, "secrets"), do: assign(socket, dialog: :secrets)
  defp open(socket, _), do: socket

  # A horde's peon starts its preview only when someone opens its chat.
  defp open_preview(
         %{assigns: %{chat: %{horde_id: id} = chat, info: %{preview_status: :off}}} = socket
       )
       when id != nil do
    Task.start(fn -> Chat.open_preview(chat.id) end)
    socket
  end

  defp open_preview(socket), do: socket

  defp start_chat(socket) do
    %{chat: %{id: id}, project: project} = socket.assigns

    socket
    |> assign(starting: true, stopped: nil, start_error: nil)
    |> start_async(:chat, fn -> Chat.ensure_started(project, id) end)
  end

  @impl true
  def handle_async(:chat, {:ok, {:ok, info}}, socket) do
    socket = socket |> assign(info: info, starting: false) |> default_view() |> open_preview()

    case socket.assigns.pending do
      nil ->
        {:noreply, socket}

      text ->
        images = socket.assigns.pending_images
        {:noreply, socket |> assign(pending: nil, pending_images: []) |> prompt(text, images)}
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

  def handle_async(:horde, {:ok, {:ok, _horde}}, socket), do: {:noreply, load_horde(socket)}

  def handle_async(:horde, {:ok, {:error, text}}, socket),
    do: {:noreply, put_flash(socket, :error, text)}

  def handle_async(:horde, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, "The horde didn't start: #{inspect(reason)}")}

  def handle_async(:design_pending, {:ok, {id, pending}}, socket) do
    if socket.assigns.chat && socket.assigns.chat.id == id,
      do: {:noreply, assign(socket, design_pending: pending)},
      else: {:noreply, socket}
  end

  def handle_async(:design_pending, _result, socket), do: {:noreply, socket}

  @impl true
  # A disabled chat box sends no text. "Queue" puts the text in the chat's
  # queue instead, for the agent to take when it gets to it.
  def handle_event("send", params, socket) do
    text = String.trim(params["text"] || "")
    %{chat: chat, tab: tab} = socket.assigns

    cond do
      chat == nil or closed?(tab) ->
        {:noreply, socket}

      params["to"] == "queue" ->
        {:noreply, queue_it(socket, text)}

      text == "" and socket.assigns.uploads.images.entries == [] ->
        {:noreply, socket}

      true ->
        images = take_images(socket)
        text = if text == "", do: look_text(images), else: text

        {:noreply, socket |> empty_box() |> say(text, images)}
    end
  end

  def handle_event("cancel_inbox", %{"id" => id}, socket) do
    case Chat.cancel_inbox(socket.assigns.chat.id, id) do
      :ok -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Peon already has that message.")}
    end
  end

  def handle_event("cancel_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :images, ref)}

  # The queue's own box: a task for after the current one.
  def handle_event("add_ticket", %{"text" => text}, socket) do
    %{project: project, chat: chat} = socket.assigns

    with text when text != "" <- String.trim(text), do: Chat.add_ticket(project, chat.id, text)
    {:noreply, socket}
  end

  def handle_event("work_queue", _params, socket),
    do: {:noreply, say(socket, "Work through your tk queue.", [])}

  def handle_event("delete_ticket", %{"id" => id}, socket) do
    %{project: project, chat: chat} = socket.assigns

    case Chat.delete_ticket(project, chat.id, id) do
      :ok -> {:noreply, socket}
      {:error, :started} -> {:noreply, put_flash(socket, :error, "Peon has started on that one.")}
      {:error, _} -> {:noreply, assign(socket, tickets: Chat.tickets(project, chat.id))}
    end
  end

  def handle_event("clear_goal", _params, socket) do
    %{chat: chat} = socket.assigns
    Chat.clear_goal(chat.id)
    {:noreply, socket |> assign(chat: Chats.get(chat.id) || chat) |> update_info(goal: nil)}
  end

  def handle_event("typing", params, socket),
    do: {:noreply, slash_menu(socket, params["text"] || "")}

  # Plan, Build or Design, from the next message. Design shows the boards;
  # leaving it starts the preview.
  def handle_event("pick_agent", %{"agent" => agent}, socket) do
    %{chat: chat, project: project} = socket.assigns

    if agent in Chats.agents(project) do
      Chats.pick_agent(chat, agent)
      Chat.agent_picked(chat.id)
      socket = assign(socket, chat: Chats.get(chat.id))

      if agent == "design",
        do: {:noreply, socket |> assign(view: "design", overview: false) |> load_boards()},
        else: {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

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

  # The chip on a chat that starts from a general chat: it starts from scratch instead.
  def handle_event("unfrom", _params, socket) do
    %{chat: chat} = socket.assigns
    Chats.set(chat, from_chat: nil)
    {:noreply, assign(socket, chat: Map.put(chat, :from_chat, nil), from: nil)}
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
    %{project: project, current_scope: scope} = socket.assigns

    with %{} = chat <- Chats.get(project, scope.user.id, id),
         do:
           Task.Supervisor.start_child(Burrow.TaskSupervisor, fn -> Chat.delete(project, chat) end)

    if socket.assigns.chat && socket.assigns.chat.id == id,
      do: {:noreply, leave_chat(socket, id)},
      else: {:noreply, socket}
  end

  # A day group in the drawer folds to the chats still open, or unfolds.
  def handle_event("fold_day", %{"day" => day}, socket) do
    folded = socket.assigns.folded_days
    folded = if day in folded, do: List.delete(folded, day), else: [day | folded]
    Accounts.put_folded_days(socket.assigns.current_scope.user, folded)
    {:noreply, assign(socket, folded_days: folded)}
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

  # Boards picked in the grid, to build together.
  def handle_event("pick_board", %{"path" => path}, socket) do
    picked = socket.assigns.picked

    picked =
      if MapSet.member?(picked, path),
        do: MapSet.delete(picked, path),
        else: MapSet.put(picked, path)

    {:noreply, assign(socket, picked: picked)}
  end

  def handle_event("pick_all", _params, socket) do
    all = for b <- socket.assigns.boards, b.hash, into: MapSet.new(), do: b.path
    picked = if MapSet.subset?(all, socket.assigns.picked), do: MapSet.new(), else: all
    {:noreply, assign(socket, picked: picked)}
  end

  def handle_event("build_boards", _params, socket) do
    case for(b <- socket.assigns.boards, b.path in socket.assigns.picked, do: b.path) do
      [] -> {:noreply, socket}
      [path] -> {:noreply, socket |> assign(picked: MapSet.new()) |> put_in_box("Build #{path}")}
      paths -> {:noreply, socket |> assign(picked: MapSet.new()) |> put_in_box(build_text(paths))}
    end
  end

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
        {:noreply, info(socket, "Shipping ##{id}.")}

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
    {:ok, incident} =
      Incidents.fix(
        Incidents.get(String.to_integer(id)),
        socket.assigns.project,
        socket.assigns.current_scope.user
      )

    {:noreply, push_patch(socket, to: chat_path(socket, incident.chat_id))}
  end

  def handle_event("resolve_incident", %{"id" => id}, socket) do
    Incidents.resolve(Incidents.get(String.to_integer(id)))
    {:noreply, socket}
  end

  # "Deploys and usage" again: back to the preview.
  def handle_event("open", %{"open" => "deploys"}, %{assigns: %{overview: true}} = socket),
    do: {:noreply, assign(socket, overview: false)}

  def handle_event("open", %{"open" => what}, socket), do: {:noreply, open(socket, what)}

  def handle_event("restart", _params, socket) do
    Cell.restart(socket.assigns.project.id)
    {:noreply, info(socket, "Restarting #{socket.assigns.burrow_project.name}.")}
  end

  def handle_event("delete_project", _params, socket) do
    case Projects.delete(socket.assigns.current_scope, socket.assigns.burrow_project) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{project.name} is deleted.")
         |> push_navigate(to: ~p"/projects")}

      {:error, :not_owner} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can delete it.")}
    end
  end

  def handle_event("dialog", %{"dialog" => dialog}, socket)
      when dialog in ~w(new_project share hand_over secrets stop_horde) do
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
          "auth" => p.auth,
          "signups" => p.signups
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

  # The drawer lists another place's chats, or this project's again.
  def handle_event("peek", %{"place" => place}, socket),
    do: {:noreply, Peek.pick(socket, place, socket.assigns.project.id)}

  ## The open chat's horde (`Burrow.Hordes`)

  # The chat's queue runs as a horde; asking its model's thinking levels
  # can take a moment, so it starts off the page.
  def handle_event("horde_start", _params, socket) do
    %{project: project, chat: chat} = socket.assigns
    {:noreply, start_async(socket, :horde, fn -> Hordes.run_queue(project, chat.id) end)}
  end

  # The queue goes back to the agent, worked one ticket at a time.
  def handle_event("queue_one_by_one", _params, socket) do
    Chats.pick_horde(socket.assigns.chat, nil)

    {:noreply,
     socket
     |> assign(chat: Chats.get(socket.assigns.chat.id))
     |> say("Work the queue one ticket at a time.", [])}
  end

  def handle_event("horde_pause", _params, socket),
    do: {:noreply, horde(socket, fn _project, horde -> Hordes.pause(horde, "you") end)}

  def handle_event("horde_resume", _params, socket),
    do: {:noreply, horde(socket, &Hordes.resume(&1, &2))}

  def handle_event("horde_stop", params, socket),
    do:
      {:noreply,
       socket
       |> assign(dialog: nil)
       |> horde(&Hordes.stop(&1, &2, params["revert"] == "true"))}

  def handle_event("horde_revert_all", _params, socket),
    do: {:noreply, horde(socket, &Hordes.revert_all(&1, &2))}

  # One peon, looked into where the preview is (on phones, over the chat).
  def handle_event("horde_merge_all", _params, socket),
    do: {:noreply, horde(socket, &Hordes.merge_ready(&1, &2))}

  def handle_event("horde_revert", %{"n" => n}, socket) do
    n = String.to_integer(n)

    {:noreply,
     horde(socket, fn project, horde ->
       Hordes.revert(project, Enum.find(horde.peons, &(&1.n == n)), socket.assigns.user)
     end)}
  end

  # What the horde shipped, where the preview is.
  def handle_event("horde_changes", _params, socket) do
    {:noreply,
     socket
     |> assign(horde_changes: [], peon: nil, overview: false, preview_open: true, pane: "preview")
     |> load_horde()}
  end

  def handle_event("horde_changes_close", _params, socket),
    do: {:noreply, assign(socket, horde_changes: nil, pane: "chat")}

  def handle_event("peon", %{"n" => n}, socket) do
    {:noreply,
     socket
     |> assign(peon: String.to_integer(n), horde_changes: nil, overview: false)
     |> assign(preview_open: true, pane: "preview")
     |> load_horde()}
  end

  def handle_event("peon_close", _params, socket),
    do: {:noreply, assign(socket, peon: nil, peon_failure: nil, pane: "chat")}

  # As is, with a hint, or on a bigger model (`"model"`, `"effort"`).
  def handle_event("peon_retry", params, socket) do
    model = if params["model"] in [nil, ""], do: nil, else: {params["model"], params["effort"]}
    {:noreply, peon(socket, &Hordes.retry(&1, &2, params["hint"], model))}
  end

  # "Split into a horde" in the + menu, `n` peons at a time; "" turns it off.
  def handle_event("pick_horde", %{"n" => n}, socket) do
    Chats.pick_horde(socket.assigns.chat, if(n == "", do: nil, else: String.to_integer(n)))
    {:noreply, assign(socket, chat: Chats.get(socket.assigns.chat.id))}
  end

  def handle_event("pick_shipping", %{"shipping" => shipping}, socket) do
    Chats.pick_shipping(socket.assigns.chat, shipping)
    {:noreply, assign(socket, chat: Chats.get(socket.assigns.chat.id))}
  end

  # A person merges a change whose checks passed (it shipped for review, or
  # its horde paused shipping).
  def handle_event("merge", _params, socket) do
    case Ship.land_held(socket.assigns.project, socket.assigns.chat.id) do
      {:ok, change} ->
        {:noreply, socket |> info("Merged as ##{change.id}.") |> load_draft() |> load_tabs()}

      {:error, {:conflict, _}} ->
        {:noreply,
         put_flash(socket, :error, "It conflicts with main now; Peon merges and submits again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not merge: #{inspect(reason)}")}
    end
  end

  # Skipping lets what waits on it go ahead, or skips that too (`"waiting"`).
  def handle_event("peon_skip", params, socket),
    do: {:noreply, peon(socket, &Hordes.skip(&1, &2, params["waiting"] == "true"))}

  def handle_event("peon_ship", _params, socket),
    do: {:noreply, peon(socket, &Hordes.ship_now(&1, &2))}

  def handle_event("peon_revert", _params, socket),
    do: {:noreply, peon(socket, &Hordes.revert(&1, &2, socket.assigns.user))}

  def handle_event("toggle_preview", _params, socket),
    do: {:noreply, update(socket, :preview_open, &(!&1))}

  def handle_event("toggle_phone", _params, socket),
    do: {:noreply, update(socket, :phone, &(!&1))}

  def handle_event("view", %{"view" => "design"}, socket),
    do: {:noreply, socket |> assign(view: "design", overview: false) |> load_boards()}

  def handle_event("view", %{"view" => view}, socket)
      when view == "dev" or view == socket.assigns.landing,
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
  def handle_info({:tickets, tickets}, socket), do: {:noreply, assign(socket, tickets: tickets)}

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

  def handle_info({:horde, _id}, socket), do: {:noreply, socket |> load_horde() |> load_tabs()}

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
         socket
         |> assign(burrow_project: Projects.get!(scope, project.id))
         |> load_rail()
         |> Peek.reload(project.id)},
      else: {:noreply, push_navigate(socket, to: ~p"/projects")}
  end

  # The project is up: open the workspace.
  def handle_info(
        {:cell, id, :running},
        %{assigns: %{ready: false, burrow_project: %{id: id}}} = socket
      ),
      do: {:noreply, push_navigate(socket, to: socket.assigns.after_start)}

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

  # An empty chat, its box ready to type in: the one the user already has,
  # else a new one with the open chat's model. Never refused: empty chats
  # don't count against the limit, which their first message checks.
  defp new_chat(socket, opts) do
    %{project: project, current_scope: %{user: user}, chat: chat, tabs: tabs} = socket.assigns
    picked = if chat, do: [model: chat.model, effort: chat.effort], else: []

    empty =
      opts == [] &&
        Enum.find_value(tabs, fn
          %{phase: "new", chat: %{follows: nil, from_chat: nil} = empty} -> empty
          _ -> nil
        end)

    chat = empty || Chats.create_empty(project.id, user, picked ++ opts)
    socket |> push_patch(to: chat_path(socket, chat.id)) |> push_event("composer:focus", %{})
  end

  # The open chats as the drawer lists them.
  defp open_tabs(socket), do: open_chats(socket.assigns.tabs)

  # Closing the open chat opens the one above it in the drawer, else the
  # one below, else a new one.
  defp leave_chat(socket, id) do
    ids = Enum.map(open_tabs(socket), & &1.chat.id)

    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        socket

      i ->
        case Enum.at(ids, if(i > 0, do: i - 1, else: 1)) do
          nil -> new_chat(socket, [])
          other -> push_patch(socket, to: chat_path(socket, other))
        end
    end
  end

  # The general chat (Burrow.GeneralChats) an empty chat starts from.
  defp from_chat(%{started_at: nil} = chat) do
    with id when is_binary(id) <- Map.get(chat, :from_chat),
         do: Burrow.GeneralChats.get(id)
  end

  defp from_chat(_chat), do: nil

  # "Follow up on #N": change N, while the chat is empty.
  defp followed(_project, %{follows: nil}), do: nil
  defp followed(_project, %{started_at: started}) when started != nil, do: nil

  defp followed(project, %{follows: id}) do
    if !Projects.Project.repo?(project),
      do: Totem.Repo.change(Projects.repo_dir(project), id)
  end

  # While the box holds just "/name", the commands and skills it matches,
  # names starting with it first. A bare "/" reloads them: the agent may have
  # added one to the workspace. Before the agent runs, only Peon's own.
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

  defp build_text(paths), do: "Build these boards: #{Enum.join(paths, ", ")}"

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

  defp load_slash(%{assigns: %{info: nil, repo?: repo?}} = socket),
    do: assign(socket, slash_items: Chat.peon_commands(repo?))

  defp load_slash(socket) do
    case Chat.slash_commands(socket.assigns.chat.id) do
      {:ok, items} -> assign(socket, slash_items: items)
      _ -> socket
    end
  end

  # The user's message: sent if the agent runs, else it starts the agent.
  defp say(socket, text, images) do
    cond do
      socket.assigns.info && !socket.assigns.stopped ->
        prompt(socket, text, images)

      socket.assigns.starting ->
        %{pending: pending, pending_images: pending_images} = socket.assigns
        text = if pending, do: pending <> "\n\n" <> text, else: text
        assign(socket, pending: text, pending_images: pending_images ++ images)

      true ->
        socket |> assign(pending: text, pending_images: images) |> start_chat()
    end
  end

  defp prompt(socket, text, images) do
    case Chat.send_message(socket.assigns.project, socket.assigns.chat.id, text, images) do
      :ok -> update_info(socket, busy?: true)
      {:ok, :no_turn} -> socket
      {:ok, :cleared} -> put_flash(socket, :info, "Peon starts over. The files stay.")
      {:error, message} when is_binary(message) -> put_flash(socket, :error, message)
      {:error, reason} -> put_flash(socket, :error, "Could not send: #{inspect(reason)}")
    end
  end

  # The box's images, kept with the chat (`Burrow.Chat.images_dir/2`) under
  # names of their own: `[%{name, mime}]`.
  defp take_images(socket) do
    %{project: project, chat: chat} = socket.assigns
    dir = Chat.images_dir(project, chat.id)
    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
      ext = entry.client_type |> MIME.extensions() |> List.first("png")
      name = Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
      File.cp!(path, Path.join(dir, "#{name}.#{ext}"))
      {:ok, %{name: "#{name}.#{ext}", mime: entry.client_type}}
    end)
  end

  defp look_text([_]), do: "Look at this image."
  defp look_text(_images), do: "Look at these images."

  defp queue_it(socket, ""), do: socket

  defp queue_it(socket, text) do
    %{project: project, chat: chat} = socket.assigns
    Chat.add_ticket(project, chat.id, text)
    empty_box(socket)
  end

  # The box empties once its message is here: with images, the browser sends
  # the text only after they are up.
  defp empty_box(socket) do
    socket
    |> assign(form: to_form(%{"text" => ""}), slash: [])
    |> push_event("composer:put", %{text: ""})
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

  defp load_logs(%{assigns: %{view: env, landing: env}} = socket),
    do: assign(socket, logs: Env.logs(socket.assigns.project, env))

  defp load_logs(socket), do: socket

  # Every project the user can open, with what it is doing
  # (`Burrow.Activity`), and this project's sharing.
  defp load_rail(socket) do
    %{current_scope: scope, burrow_project: project} = socket.assigns

    rail =
      for p <- Projects.list(scope) do
        tile = Activity.of(p, scope.user.id)

        %{
          id: p.id,
          name: p.name,
          url: ~p"/projects/#{p.id}",
          current: p.id == project.id,
          internal: Projects.Project.internal?(p),
          state: tile["state"],
          label: tile["label"],
          pct: tile["pct"]
        }
      end

    sharing = %{
      owner?: Projects.owner?(scope, project),
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
  # A chat that planned a horde says how the horde stands (`horde_row/1`).
  defp load_tabs(socket) do
    %{project: project, current_scope: scope, busy: busy} = socket.assigns
    hordes = Hordes.by_chat(project.id)

    tabs =
      for tab <- Activity.chats(project, scope.user.id, busy),
          do: Map.put(tab, :horde, hordes[tab.chat.id] && horde_row(hordes[tab.chat.id]))

    socket |> assign(tabs: tabs) |> select_tab()
  end

  # The open chat's horde, or the horde it is a peon of, and the peon looked into.
  defp load_horde(%{assigns: %{chat: nil}} = socket), do: assign(socket, horde: nil, peon_of: nil)

  defp load_horde(socket) do
    %{chat: chat, project: project, peon: n} = socket.assigns
    horde = Hordes.for_chat(chat.id)
    peon = horde && n && Enum.find(horde.peons, &(&1.n == n))

    failure =
      with %{status: "needs_you", chat_id: id} when id != nil <- peon,
           %{checks: %{"steps" => [_ | _] = steps}} <-
             Totem.Repo.draft(Projects.repo_dir(project), id),
           do: List.last(steps)["output"]

    peon_chat = peon && peon.chat_id && Chats.get(peon.chat_id)

    assign(socket,
      horde: horde,
      peon: peon && n,
      peon_failure: if(is_binary(failure) and failure != "", do: failure),
      peon_model:
        peon_chat && {peon_chat.model || socket.assigns.default_model, peon_chat.effort},
      peon_of: chat.horde_id && Hordes.peon_of(chat.id),
      horde_errors:
        if(horde && horde.paused_by == "errors", do: Hordes.errors_of(horde), else: []),
      horde_changes: horde && socket.assigns.horde_changes && Hordes.changes(project, horde)
    )
  end

  # Does `fun` to the open chat's horde; the horde's broadcast redraws it.
  defp horde(%{assigns: %{horde: %Hordes.Horde{} = horde}} = socket, fun) do
    fun.(socket.assigns.project, Hordes.get!(horde.id))
    load_horde(socket)
  end

  defp horde(socket, _fun), do: socket

  defp peon(%{assigns: %{horde: %Hordes.Horde{} = horde, peon: n}} = socket, fun) when n != nil do
    horde = Hordes.get!(horde.id)
    fun.(socket.assigns.project, Enum.find(horde.peons, &(&1.n == n)))
    load_horde(socket)
  end

  defp peon(socket, _fun), do: socket

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
        nothing_built?: Totem.Repo.ref(Projects.repo_dir(project), Env.live(project)) == nil
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
    if dev?(socket.assigns),
      do: assign(socket, view: "dev"),
      else: assign(socket, view: socket.assigns.landing)
  end

  # The dev preview stays until the chat's change is on prod, to look into
  # it while it waits on main or staging (`Burrow.Chat` keeps it running).
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
      signups: false,
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
    fields =
      for {key, field} <- @new_project_fields,
          is_binary(params[key]),
          into: %{},
          do: {field, String.trim(params[key])}

    # The checkbox sends "true", its hidden twin "false" when unchecked.
    if is_binary(params["signups"]),
      do: Map.put(fields, :signups, params["signups"] == "true"),
      else: fields
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
        follows: assigns.chat && assigns.chat.started_at == nil && assigns.followed,
        from: assigns.chat && assigns.chat.started_at == nil && assigns[:from],
        goal: goal(assigns),
        done?: assigns.tab != nil and Activity.done?(assigns.tab),
        busy?: assigns.info != nil and assigns.info.busy?,
        blocks: blocks((assigns.info && assigns.info.messages) || [])
      )

    assigns =
      assign(assigns,
        queue?: assigns.chat != nil and assigns.tickets != [] and not assigns.done?,
        cards?:
          match?(%{status: "failed"}, assigns.main_check) or assigns.board_card != nil or
            (assigns.chat != nil and asked(assigns.secrets, assigns.chat.id) != []) or
            (assigns.draft != nil and not Design.only?(assigns.draft.files))
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="ws-root" data-pane={@pane} data-preview={if @preview_open, do: "open", else: "closed"}>
      <div
        class="ws-scrim"
        aria-hidden="true"
        data-kb-dismiss
        phx-click={JS.remove_class("show-drawer", to: ".ws-root")}
      >
      </div>
      <.drawer
        rail={@rail}
        status={status_line(assigns)}
        tabs={drawer_tabs(@tabs)}
        chat={drawer_chat(@chat, @peon_of)}
        project={@project}
        base={@base}
        folded={@folded_days}
        user={@current_scope.user}
        nothing_built?={@nothing_built?}
        repo?={@repo?}
        peek={@peek}
      />
      <div id="theme" phx-hook=".Theme" data-theme={@theme} hidden></div>
      <.rail new_chat={JS.push("new_chat")} user={@current_scope.user} />

      <div class="ws-main">
        <div class="ws-split">
          <main
            class="ws-chat"
            aria-label={"#{@project && @project.name} chats"}
            data-kb-zoom-hide
          >
            <.chat_bar
              title={if @tab, do: chat_title(@tab, @project, @nothing_built?), else: ""}
              project={@project}
              ctx={ctx(assigns)}
              status={chat_status(assigns)}
              meta={meta(assigns)}
              overview={@overview}
              sharing={@sharing}
              repo?={@repo?}
              secrets={@secrets}
              open_incidents={@open_incidents}
              preview_open={@preview_open}
              preview_tone={if @view == "design", do: "idle", else: st_tone(@preview.status)}
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
                  <p :if={@from} class="muted">
                    Peon starts from your chat “{@from.title}” in Chats: what you asked and what it found.
                  </p>
                </div>
                <div :if={@peon_of} id="peon-of" class="evt note" role="note">
                  <span class="ln"></span>
                  <span class="mono">
                    Peon #{@peon_of.n} of a horde ·
                    <.link
                      patch={~p"/projects/#{@project.id}/c/#{@peon_of.horde.chat_id}"}
                      class="underline"
                    >
                      Back to the horde
                    </.link>
                  </span>
                  <span class="ln"></span>
                </div>
                <div :if={@starting} class="ws-working" role="status">
                  <.icon name="hero-arrow-path" class="size-4 spin" /> Starting the agent and preview…
                </div>
                <div :if={@start_error} class="say-error">{@start_error}</div>
                <%= for {block, i} <- Enum.with_index(@blocks) do %>
                  <.block
                    block={block}
                    images={@images_url}
                    live={@busy? and i == length(@blocks) - 1}
                  />
                <% end %>
                <div :if={@pending} class="bubble-user opacity-60">{@pending}</div>
                <.horde_queue
                  :if={queue?(assigns)}
                  tickets={Burrow.Tickets.unfinished(@tickets)}
                  at_once={@chat.horde_at_once || 4}
                  shipping={horde_shipping(assigns)}
                />
                <.horde_card
                  :if={@horde && @horde.status != "planned"}
                  horde={@horde}
                  selected={@peon}
                  shipping={horde_shipping(assigns)}
                  main={@main_check && @main_check.change_id}
                  errors={@horde_errors}
                />
                <div
                  :for={m <- (@info && @info[:inbox]) || []}
                  id={"inbox-#{m.id}"}
                  class="ws-inbox"
                >
                  <.block block={{:user, m}} images={@images_url} />
                  <div class="meta">
                    Peon reads this after its current step
                    <button
                      type="button"
                      phx-click="cancel_inbox"
                      phx-value-id={m.id}
                      class="xlink"
                      aria-label="Take this message back"
                    >
                      Take back
                    </button>
                  </div>
                </div>
                <div
                  :if={@info && !@info.busy? && @info[:note]}
                  id="run-note"
                  class={["evt", elem(@info.note, 0)]}
                  role="note"
                >
                  <span class="ln"></span><span class="mono">{elem(@info.note, 1)}</span><span class="ln"></span>
                </div>
                <div
                  :if={event = event_line(@tab)}
                  class={["evt", event.tone]}
                  role="note"
                >
                  <span class="ln"></span><span class="mono">{event.text}</span><span class="ln"></span>
                </div>
              </div>
            </div>

            <div :if={@cards?} class="ws-cards">
              <div :if={@main_check && @main_check.status == "failed"} class="notice err">
                <span>Main #{@main_check.change_id} did not pass in prod mode.</span>
              </div>
              <.connect_card
                :if={@chat && asked(@secrets, @chat.id) != []}
                secrets={asked(@secrets, @chat.id)}
                key={@secrets_key}
              />
              <.design_card :if={@board_card} card={@board_card} />
              <.change_card
                :if={@draft && !Design.only?(@draft.files)}
                draft={@draft}
                tab={@tab}
                step={@step}
                promote={@promote}
                main_check={@main_check}
              />
            </div>

            <div id="box" class="ws-bottom ws-box" phx-hook=".Pops">
              <.chat_done
                :if={@done?}
                tab={@tab}
                attach?={@info != nil}
              />
              <pre :if={@done? && @info && @show_attach} class="out mono">{@info.attach}</pre>
              <.horde_bar :if={@horde && @horde.status in ~w(running paused)} horde={@horde} />
              <div :if={(@busy? or @queue?) and !@done?} id="status-bar" class="ws-now">
                <div :if={@busy?} class="ws-scene">
                  <.peon_at_work job={job(@info.messages)} stage={stage(@info.messages)} />
                </div>
                <button
                  id="queue-link"
                  type="button"
                  class="qlink"
                  aria-haspopup="dialog"
                  aria-expanded="false"
                  phx-click={
                    JS.toggle(to: "#queue-pop", display: "flex")
                    |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                  }
                >
                  <span :if={@busy?} class="now" role="status">
                    {if @info[:judging?], do: "Checking the goal…", else: doing(@info.messages)}
                  </span>
                  <span class="sub">
                    <span
                      :if={@busy? && @info[:since]}
                      id="elapsed"
                      class="mono"
                      phx-hook=".Elapsed"
                      phx-update="ignore"
                      data-since={@info.since}
                    ></span><span :if={@busy? && @info[:since]} aria-hidden="true">·</span>
                    <span>Queue · {queue_next(@tickets)}</span>
                    <.icon name="hero-chevron-up" class="size-3.5" />
                  </span>
                </button>
                <.queue_card tickets={@tickets} busy?={@busy?} />
              </div>
              <.form
                :if={!@done?}
                for={@form}
                id="composer"
                phx-submit="send"
                phx-change="typing"
                phx-drop-target={@uploads.images.ref}
                class={["composer", @chat && @chat.agent == "design" && "design"]}
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
                <span :if={@from} id="from-chip" class="ctx">
                  <span>↳ from Chats: {@from.title}</span>
                  <button
                    type="button"
                    class="cx"
                    phx-click="unfrom"
                    aria-label="Don't start from the chat in Chats"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </span>
                <span :if={@goal} id="goal-chip" class="ctx">
                  <.icon name="hero-flag" class="size-3.5 shrink-0" />
                  <span>Goal: {@goal}</span>
                  <button
                    type="button"
                    class="cx"
                    phx-click="clear_goal"
                    aria-label="Drop the goal"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </span>
                <div :if={@uploads.images.entries != []} id="composer-images" class="shots">
                  <div :for={entry <- @uploads.images.entries} class="shot">
                    <.live_img_preview entry={entry} />
                    <button
                      type="button"
                      class="cx"
                      phx-click="cancel_image"
                      phx-value-ref={entry.ref}
                      aria-label={"Remove #{entry.client_name}"}
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                    <span :for={err <- upload_errors(@uploads.images, entry)} class="err">
                      {image_error(err)}
                    </span>
                  </div>
                </div>
                <p :for={err <- upload_errors(@uploads.images)} class="say-error">
                  {image_error(err)}
                </p>
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
                  rows="1"
                  id="chat-input"
                  data-kb="search"
                  data-kb-label="Chat box"
                  phx-hook=".SubmitOnEnter"
                  disabled={closed?(@tab)}
                  placeholder={placeholder(@tab, @follows)}
                >{@form[:text].value}</textarea>
                <div class="cbar">
                  <div :if={@chat && !closed?(@tab)} class="menuw plusw">
                    <button
                      id="plus-btn"
                      type="button"
                      class="icon-btn plus"
                      aria-label="Agent, model and attachments"
                      aria-haspopup="dialog"
                      aria-expanded="false"
                      phx-click={toggle_plus()}
                    >
                      <.icon name="hero-plus" class="size-5" />
                    </button>
                    <div
                      id="plus-pop"
                      class="pop plus-pop"
                      role="dialog"
                      aria-label="Message options"
                      style="display: none"
                    >
                      <button type="button" class="qscrim" aria-label="Close" phx-click={hide_plus()}></button>
                      <div class="psheet" phx-click-away={hide_plus()}>
                        <div class="h">Agent</div>
                        <.agent_pick chat={@chat} agents={Chats.agents(@project)} />
                        <p class="mhelp">{agent_help(@chat.agent)}</p>
                        <div :if={!@repo?} class="msep" role="separator"></div>
                        <div :if={!@repo?} class="h">Shipping</div>
                        <div
                          :if={!@repo?}
                          id="shipping-pick"
                          class="shipseg"
                          role="radiogroup"
                          aria-label="Shipping"
                        >
                          <button
                            :for={{value, label} <- shipping_modes(@project)}
                            type="button"
                            role="radio"
                            aria-checked={to_string((@chat.shipping || "") == value)}
                            phx-click="pick_shipping"
                            phx-value-shipping={value}
                          >
                            {label}
                          </button>
                        </div>
                        <p :if={!@repo?} class="mhelp">{shipping_help(assigns)}</p>
                        <div :if={!@repo? && !@chat.horde_id} class="msep" role="separator"></div>
                        <div :if={!@repo? && !@chat.horde_id} id="horde-pick" class="hordepick">
                          <label class="horderow">
                            <span class="flex-1 min-w-0">
                              <span class="block font-medium">Split into a horde</span>
                              <span class="mhelp block">
                                Peon splits big tasks into peons by itself. Each gets its own checkout and preview, and ships on its own.
                              </span>
                            </span>
                            <input
                              id="horde-on"
                              type="checkbox"
                              role="switch"
                              checked={@chat.horde_at_once != nil}
                              phx-click="pick_horde"
                              phx-value-n={if @chat.horde_at_once, do: "", else: "4"}
                            />
                          </label>
                          <div :if={@chat.horde_at_once} class="horde-meta">
                            <span class="atonce">
                              Peons at once
                              <button
                                type="button"
                                class="icon-btn"
                                aria-label="Fewer at once"
                                phx-click="pick_horde"
                                phx-value-n={@chat.horde_at_once - 1}
                                disabled={@chat.horde_at_once <= 1}
                              >
                                <.icon name="hero-minus" class="size-4" />
                              </button>
                              <b>{@chat.horde_at_once}</b>
                              <button
                                type="button"
                                class="icon-btn"
                                aria-label="More at once"
                                phx-click="pick_horde"
                                phx-value-n={@chat.horde_at_once + 1}
                                disabled={@chat.horde_at_once >= Hordes.max_at_once()}
                              >
                                <.icon name="hero-plus" class="size-4" />
                              </button>
                            </span>
                          </div>
                          <p :if={@chat.horde_at_once} class="mhelp">
                            Guardrails: checks must pass · a peon stops after {Hordes.max_fails()} failed tries · the horde pauses when main goes red or errors show up
                          </p>
                        </div>
                        <div class="msep" role="separator"></div>
                        <div class="h">Model</div>
                        <div class="picks">
                          <.model_pick chat={@chat} models={@models} default={@default_model} />
                        </div>
                        <div class="msep" role="separator"></div>
                        <label class="mi" title="Or paste them into the box">
                          <.icon name="hero-photo" class="size-[18px]" />
                          <span class="flex-1">Attach a photo</span>
                          <.live_file_input upload={@uploads.images} class="sr-only" />
                        </label>
                        <button
                          :if={@info}
                          id="opencode-btn"
                          type="button"
                          class="mi"
                          phx-click={hide_plus() |> JS.push("toggle_attach")}
                        >
                          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                          <span class="flex-1">Open in opencode</span>
                        </button>
                      </div>
                    </div>
                  </div>
                  <button
                    :if={@chat && @chat.agent in ~w(plan design) && !closed?(@tab)}
                    id="agent-chip"
                    type="button"
                    class="chip on"
                    phx-click={toggle_plus()}
                  >
                    <.icon
                      name={if @chat.agent == "design", do: "hero-swatch", else: "hero-light-bulb"}
                      class="size-3.5"
                    />
                    <span>{if @chat.agent == "design", do: "Design only", else: "Plan"}</span>
                  </button>
                  <button
                    :if={@chat && @chat.horde_at_once && !@repo? && !closed?(@tab)}
                    id="horde-chip"
                    type="button"
                    class="chip on"
                    phx-click={toggle_plus()}
                  >
                    <.icon name="hero-user-group" class="size-3.5" />
                    <span>Horde · {@chat.horde_at_once}</span>
                  </button>
                  <button
                    :if={@chat && @chat.shipping in ~w(review pilot) && !@repo? && !closed?(@tab)}
                    id="shipping-chip"
                    type="button"
                    class="chip on"
                    phx-click={toggle_plus()}
                  >
                    <.icon
                      name={if @chat.shipping == "pilot", do: "hero-bolt", else: "hero-eye"}
                      class="size-3.5"
                    />
                    <span>{if @chat.shipping == "pilot", do: "Autopilot", else: "Review"}</span>
                  </button>
                  <button
                    :if={@chat && !closed?(@tab)}
                    type="button"
                    class="chip mchip"
                    phx-click={toggle_plus()}
                  >
                    <span>{model_words(@chat, @default_model)}</span>
                  </button>
                  <div class="flex-1"></div>
                  <button
                    :if={@busy?}
                    id="stop-btn"
                    type="button"
                    class="go-stop"
                    aria-label="Stop Peon"
                    title="Stop Peon"
                    phx-click="interrupt"
                    data-kb-key="x"
                    data-kb-label="Stop the agent"
                    data-kb-group="Agent & preview"
                    data-kb-esc
                  >
                    <.icon name="hero-stop-solid" class="size-4" />
                  </button>
                  <div id="send" class={["sendw", @busy? && "with-stop"]} phx-hook=".SendHold">
                    <button
                      id="send-btn"
                      class="icon-btn go-send"
                      aria-label="Send"
                      aria-haspopup="menu"
                      title="Send (Enter). Hold it, or press Alt+Enter, to queue it instead."
                      disabled={closed?(@tab)}
                    >
                      <.icon name="hero-arrow-up" class="size-4" />
                    </button>
                    <div id="send-menu" class="menu send-menu" role="menu" style="display: none">
                      <button
                        id="queue-btn"
                        name="to"
                        value="queue"
                        role="menuitem"
                        disabled={closed?(@tab)}
                      >
                        Queue it instead<span class="k">Alt+↵</span>
                      </button>
                    </div>
                  </div>
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
              tabs={@tabs}
              info={@info}
              promote={@promote}
              auto_promote={@auto_ship}
              incidents={@incidents}
              deploys={@deploys}
              base={@base}
            />
            <.peon_detail
              :if={!@overview && @horde && @peon}
              horde={@horde}
              peon={Enum.find(@horde.peons, &(&1.n == @peon))}
              failure={@peon_failure}
              models={@models}
              model={@peon_model}
              review={@chat && @chat.shipping == "review"}
            />
            <.horde_changes
              :if={!@overview && @horde && !@peon && @horde_changes}
              horde={@horde}
              changes={@horde_changes}
            />
            <.preview_pane
              :if={!@overview && !(@horde && (@peon || @horde_changes))}
              preview={@preview}
              view={@view}
              env_names={@env_names}
              envs={@envs}
              dev?={@dev?}
              number={@draft && @draft.change}
              chat={@chat}
              info={@info}
              frame_key={@frame_key}
              phone={@phone}
              show_logs={@show_logs}
              logs={@logs}
              project={@project}
              design={@design}
              now={@busy? && doing(@info.messages)}
            >
              <.design_pane
                boards={@boards}
                picked={@picked}
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
        admin={@current_scope.user.admin}
      />
      <.share_dialog :if={@dialog == :share} sharing={@sharing} project={@project} />
      <.hand_over_dialog :if={@dialog == :hand_over} sharing={@sharing} project={@project} />
      <.secrets_dialog :if={@dialog == :secrets} secrets={@secrets} key={@secrets_key} />
      <.stop_dialog :if={@dialog == :stop_horde && @horde} horde={@horde} />
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Theme">
      // The user's theme on <html>; Burrow keeps it for the next page load.
      export default {
        mounted() { this.apply() },
        updated() { this.apply() },
        apply() { document.documentElement.dataset.theme = this.el.dataset.theme }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Elapsed">
      // How long Peon has been on this turn: "0:42", "1 h 5 min".
      export default {
        mounted() { this.tick(); this.timer = setInterval(() => this.tick(), 1000) },
        updated() { this.tick() },
        destroyed() { clearInterval(this.timer) },
        tick() {
          const s = Math.max(0, Math.floor((Date.now() - Number(this.el.dataset.since)) / 1000))
          this.el.textContent = s < 3600
            ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`
            : `${Math.floor(s / 3600)} h ${Math.floor(s / 60) % 60} min`
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Pops">
      // Esc closes the queue or the + menu first; only then is it Stop
      // (data-kb-esc), so putting a menu away never stops Peon.
      export default {
        mounted() {
          this.onKey = e => {
            if (e.key !== "Escape") return
            const open = [...this.el.querySelectorAll(".pop")].filter(p => p.offsetParent !== null || getComputedStyle(p).display !== "none")
            if (!open.length) return
            e.preventDefault()
            e.stopPropagation()
            open.forEach(p => this.js().hide(p))
          }
          window.addEventListener("keydown", this.onKey, true)
        },
        destroyed() { window.removeEventListener("keydown", this.onKey, true) }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SendHold">
      // The send button: a tap sends; holding it (or a right-click) opens
      // "Queue it instead" rather than sending.
      export default {
        mounted() {
          const button = this.el.querySelector("#send-btn")
          const menu = this.el.querySelector("#send-menu")
          let timer = null
          let held = false
          const open = () => {
            held = true
            this.js().show(menu, {display: "flex"})
            menu.querySelector("button")?.focus()
          }
          const close = () => this.js().hide(menu)
          const cancel = () => clearTimeout(timer)
          button.addEventListener("pointerdown", e => {
            if (button.disabled || e.button !== 0) return
            held = false
            timer = setTimeout(open, 450)
          })
          for (const type of ["pointerup", "pointerleave", "pointercancel"]) button.addEventListener(type, cancel)
          button.addEventListener("click", e => {
            if (held) e.preventDefault()
            held = false
          })
          button.addEventListener("contextmenu", e => {
            e.preventDefault()
            cancel()
            if (!button.disabled) open()
          })
          menu.addEventListener("click", () => setTimeout(close))
          menu.addEventListener("keydown", e => {
            if (e.key === "Escape") { close(); button.focus() }
          })
          this.away = e => { if (!this.el.contains(e.target)) close() }
          document.addEventListener("pointerdown", this.away)
        },
        destroyed() { document.removeEventListener("pointerdown", this.away) }
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
          // The box grows with its text up to its max-height, then scrolls,
          // all the way down while typing at the end so that line isn't in the fade
          this.fit = () => {
            const el = this.el
            el.style.height = "auto"
            el.style.height = el.scrollHeight + "px"
            if (el.selectionEnd === el.value.length) el.scrollTop = el.scrollHeight
          }
          this.el.addEventListener("input", this.fit)
          this.fit()
          this.handleEvent("composer:focus", () => this.el.focus())
          this.handleEvent("composer:put", ({text}) => {
            this.el.value = text
            this.fit()
            this.el.focus()
            this.el.setSelectionRange(text.length, text.length)
          })
          // Pasted images go with the message
          this.el.addEventListener("paste", e => {
            const files = [...(e.clipboardData?.files || [])].filter(f => f.type.startsWith("image/"))
            if (files.length) { e.preventDefault(); this.upload("images", files) }
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
            // Alt+Enter puts it in the queue instead
            // With images the text goes once they are up, so the box keeps
            // it until the server empties it ("composer:put")
            const images = document.querySelector("#composer-images .shot")
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              if (e.altKey) this.el.form.requestSubmit(document.getElementById("queue-btn"))
              else this.el.form.requestSubmit()
              if (!images) { this.el.value = ""; this.fit() }
            }
          })
        },
        updated() { this.fit() }
      }
    </script>
    """
  end

  # The open chat's goal: what its agent says while it runs, else its row's.
  # The box's + menu: the agent, the model, a photo, opencode.
  defp toggle_plus,
    do:
      JS.toggle(to: "#plus-pop", display: "flex")
      |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#plus-btn")

  defp hide_plus,
    do: JS.hide(to: "#plus-pop") |> JS.set_attribute({"aria-expanded", "false"}, to: "#plus-btn")

  defp agent_help("plan"), do: "Peon reads and plans. It won't change any files."

  defp agent_help("design"),
    do: "Peon draws boards in design/ and won't touch the code until you say “Build this”."

  defp agent_help(_build), do: "Peon changes the code, runs the checks and hands in the change."

  # How the chat's change ships (`Burrow.Ship`); an internal app has no prod.
  defp shipping_modes(project) do
    modes = [{"review", "Review"}, {"", "Auto-merge"}, {"pilot", "Autopilot"}]
    if Projects.Project.internal?(project), do: Enum.drop(modes, -1), else: modes
  end

  defp shipping_help(%{chat: %{shipping: "review"}}),
    do: "Peon runs the checks, then waits for you to merge the change."

  defp shipping_help(%{chat: %{shipping: "pilot"}}),
    do:
      "Merges when the checks pass, then ships to prod by itself once staging runs it without errors."

  defp shipping_help(%{project: project, auto_ship: auto_ship}) do
    cond do
      Projects.Project.internal?(project) -> "Merges and goes live when the checks pass."
      auto_ship -> "Merges when the checks pass; the project ships everything to prod."
      true -> "Merges when the checks pass and goes to staging. You ship to prod."
    end
  end

  # "beam-free · default": the chat's model, without its provider, and thinking level.
  defp model_words(chat, default) do
    model = (chat.model || default || "") |> String.split("/", parts: 2) |> List.last()
    "#{model} · #{chat.effort || "default"}"
  end

  defp goal(%{info: %{goal: goal}}), do: goal
  defp goal(%{chat: %{goal: goal}}), do: goal
  defp goal(_assigns), do: nil

  defp image_error(:too_large), do: "Images can be at most 10 MB."
  defp image_error(:too_many_files), do: "At most 4 images at once."
  defp image_error(:not_accepted), do: "Only PNG, JPEG, GIF and WebP images."
  defp image_error(error), do: "That image didn't upload: #{error}"

  # The board the agent draws right now: what its latest tool call writes.
  defp drawing(%{info: %{busy?: true, messages: messages}}) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role not in [:user, :note]))
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

  # A view that isn't there falls back to staging (or live).
  defp effective_view(%{view: "dev"} = assigns),
    do: if(dev?(assigns), do: "dev", else: assigns.landing)

  defp effective_view(%{view: "design", repo?: true} = assigns), do: assigns.landing
  defp effective_view(%{view: view}), do: view

  # "working · prod #8": what the project does, and what is out.
  defp status_line(assigns) do
    label = Enum.find_value(assigns.rail, "", &(&1.current && &1.label))
    live = List.last(assigns.env_names)
    out = if id = assigns.envs[live][:deployed], do: "##{id}", else: "—"

    if assigns.repo?, do: label, else: "#{label} · #{live} #{out}"
  end

  # The line under the chat's title: "watchtower", a repo project's repo,
  # and whom it is shared with.
  # The chat's queue waits to run as a horde: it holds tickets nobody started
  # (two or more, unless the chat is in horde mode), and no horde runs it now.
  defp queue?(%{chat: %{horde_id: nil} = chat, repo?: false, busy?: false} = assigns) do
    open = Burrow.Tickets.unfinished(assigns.tickets)

    open != [] and Enum.all?(open, &(&1.status == "open")) and
      (chat.horde_at_once != nil or length(open) > 1) and
      not match?(%{status: status} when status in ~w(running paused), assigns.horde)
  end

  defp queue?(_assigns), do: false

  # A horde's peons open from their horde's chat, never from the drawer;
  # while one is open, the drawer marks its horde's chat.
  defp drawer_tabs(tabs), do: Enum.reject(tabs, &Chats.peon?(&1.chat))

  defp drawer_chat(_chat, %{horde: %{chat_id: id}}), do: Chats.get(id)
  defp drawer_chat(chat, _peon_of), do: chat

  # Where a horde's peons ship, as the chat that planned it ships (`Burrow.Ship`).
  defp horde_shipping(%{chat: %{shipping: "review"}}), do: "Review: you merge each"
  defp horde_shipping(%{chat: %{shipping: "pilot"}}), do: "Autopilot: on to prod"

  defp horde_shipping(%{project: project, auto_ship: auto_ship}) do
    cond do
      Projects.Project.internal?(project) -> "Auto-merge, then live"
      auto_ship -> "Auto-merge, on to prod"
      true -> "Auto-merge, on to staging"
    end
  end

  defp ctx(%{project: nil}), do: []

  defp ctx(%{project: project, sharing: sharing, repo?: repo?} = assigns) do
    repo = if repo?, do: [repo_name(project)], else: []
    shared = if sharing && sharing.team, do: ["shared with #{sharing.team.name}"], else: []
    horde = with %{n: n} <- assigns.peon_of, do: ["peon ##{n} of a horde"], else: (_ -> [])
    [project.slug] ++ repo ++ shared ++ horde
  end

  # Where the open chat's change stands (Components.row_status/2), its number with it.
  defp chat_status(%{tab: nil}), do: nil

  defp chat_status(%{tab: tab}) do
    {text, tone} = row_status(tab)

    case tab.draft do
      %{change: id} when id != nil -> {"##{id} #{String.downcase(text)}", tone}
      _ -> {text, tone}
    end
  end

  # "watchtower · staging #9 · prod #8 · shared with Ops"
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
      if assigns.repo?,
        do: [project.slug, "from #{repo_name(project)}"],
        else: [project.slug | Enum.map(assigns.env_names, &"#{&1} #{tag.(&1)}")]

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
    do: "Merged. Start a new chat for the next change."

  defp placeholder(_tab, %{}), do: "What should change next?"
  defp placeholder(%{phase: "new"}, _follows), do: "Describe the change"
  defp placeholder(_tab, _follows), do: "Message Peon · / for commands"

  # The line under the thread once the chat's change is merged.
  defp event_line(%{phase: "landing", internal: true, draft: %{change: id}}),
    do: %{text: "##{id} merged · going live", tone: nil}

  defp event_line(%{phase: "live", internal: true, draft: %{change: id}}),
    do: %{text: "##{id} is live", tone: "ok"}

  defp event_line(%{phase: "landing", draft: %{change: id}}),
    do: %{text: "##{id} merged · going to staging", tone: nil}

  defp event_line(%{phase: "staged", draft: %{change: id}}),
    do: %{text: "##{id} on staging", tone: "ok"}

  defp event_line(%{phase: "live", draft: %{change: id}}),
    do: %{text: "##{id} shipped to prod", tone: "ok"}

  defp event_line(_tab), do: nil

  # What the preview pane shows: the chat's dev preview, or staging (live).
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

  defp preview(%{view: env, envs: envs} = assigns) do
    case envs[env] do
      %{deployed: id, status: {:crashed, _}} = info when id != nil ->
        %{
          url: info.url,
          status: info.status,
          ref: "##{id}",
          live?: false,
          down: env,
          message: "#{env} is down"
        }

      %{deployed: id} = info when id != nil ->
        # Staging lets Burrow frame it (`Burrow.Env.frame_ancestors/0`); an
        # internal app's live is shown through Burrow, which logs you in.
        %{
          url: info.url,
          frame: if(env == "live", do: ~p"/projects/#{assigns.project}/app"),
          status: info.status,
          ref: "##{id}",
          live?: info.status == :running,
          message: env_message(env, info)
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
        {[{:peon, turn_items(agent), ack?}], false}
    end)
    |> elem(0)
  end

  # The tool calls of the turn so far, latest first.
  defp turn_tools(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role not in [:user, :note]))
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
  defp activity({"peon_pull_request", _}), do: "Reading the pull request…"
  defp activity({"peon_comment_on_pull_request", _}), do: "Commenting on the pull request…"
  defp activity(_), do: "Working on it…"

  defp preview_message(:starting),
    do: "Starting the preview (the first start fetches and compiles dependencies)…"

  defp preview_message({:crashed, code}),
    do: "The preview stopped (exit #{code}). Check the logs or restart it."

  defp preview_message(:no_pack),
    do: "This repo has no .peon/preview.json yet. Ask the agent to add one for a preview."

  defp preview_message({:pack_error, message}),
    do: "The preview pack (.peon/preview.json) needs fixing: #{message}"

  defp preview_message(:off),
    do: "Peon is in Design mode: no preview. It starts when you switch to Build or Plan."

  defp preview_message(_), do: ""

  defp stopped_message(:idle),
    do:
      "The agent and preview stopped after 30 minutes without use. Send a message or start them again."

  defp stopped_message(:room),
    do:
      "Stopped to make room: at most #{Chat.max_running()} chats run at once, across projects. Send a message or start it again."

  defp stopped_message(:shipped),
    do:
      "Its change shipped, so its agent, preview and checkout were cleaned up. Send a message to start it again from main."

  defp stopped_message(_),
    do: "The agent and preview stopped. Send a message or start them again."

  defp env_message(name, %{deploy: %{target: id}}) when id != nil,
    do: "Deploying ##{id} to #{name}…"

  defp env_message(name, info), do: "#{String.capitalize(name)}: #{env_text(info)}"
end
