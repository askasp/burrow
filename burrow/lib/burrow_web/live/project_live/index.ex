defmodule BurrowWeb.ProjectLive.Index do
  @moduledoc """
  The projects screen: a card per project, yours and those shared with your
  teams, with what it is doing (`Burrow.Activity`), its latest change and
  its chats. A card opens the project's workspace; its ⋯ menu restarts the
  project and, for its owner, shares, hands over, adds staging and prod or
  deletes it. New project, by the title, opens the form. + starts a chat:
  the page has no "here", so it asks where (Chats, a project, or a new
  project), next to the rail on wide screens and from the bottom on phones.
  Under "No project", Chats with the latest general chats.
  """

  use BurrowWeb, :live_view

  import BurrowWeb.WorkspaceLive.Components,
    only: [place_switch: 1, account_menu: 1, rail: 1, all_projects: 1, peek_list: 1, peek: 1]

  alias Burrow.{Activity, Cell, Chat, Chats, GeneralChats, Projects, Teams}
  alias Burrow.Projects.Project
  alias BurrowWeb.{ChatsLive, Peek}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cell.subscribe()
      Projects.subscribe()
      Teams.subscribe()
      Activity.subscribe()
    end

    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Projects", ai_connected: nil)
     |> assign(form: new_form(), slug: nil)
     |> assign(menu: nil, dialog: nil, peek: nil)
     |> load()
     |> first_peek()
     |> then(&assign(&1, creating: &1.assigns.projects == []))
     |> start_async(:ai, fn -> Burrow.OpenCode.connected?(scope.user.id) end)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list(scope)

    socket
    |> assign(
      projects: projects,
      cards: Map.new(projects, &{&1.id, card(&1)}),
      rail: Enum.map(projects, &rail_entry/1),
      teams: Teams.list(scope),
      recent: GeneralChats.list(scope.user.id) |> Enum.filter(& &1.started_at) |> Enum.take(3)
    )
    |> Peek.reload(nil)
  end

  # + asks where to start a chat; picking a place opens a fresh one there.
  defp show_start, do: JS.show(to: "#start-chat")
  defp hide_start, do: JS.hide(to: "#start-chat")

  # The drawer opens on the project opened last, else on Chats.
  defp first_peek(socket) do
    socket = Peek.pick(socket, socket.assigns.current_scope.user.last_project_id || "chats", nil)
    if socket.assigns.peek, do: socket, else: Peek.pick(socket, "chats", nil)
  end

  # A project as the drawer's "Switch to" lists it.
  defp rail_entry(project) do
    tile = Activity.of(project)

    %{
      id: project.id,
      name: project.name,
      url: ~p"/projects/#{project.id}",
      current: false,
      state: tile["state"],
      label: tile["label"],
      pct: tile["pct"]
    }
  end

  # What a row shows besides the project's own fields: its status, main's
  # latest change and where the refs are (a repo project has neither; its
  # history is in git), and its chats.
  defp card(project) do
    phases = for c <- Activity.chats(project, Chat.busy_ids(project.id)), do: c.phase

    {latest, refs} =
      if Project.repo?(project) do
        {nil, %{}}
      else
        dir = Projects.repo_dir(project)
        refs = Totem.Repo.refs(dir)
        {refs["main"] && Totem.Repo.change(dir, refs["main"]), refs}
      end

    {st, job, label, sub} = status(Activity.of(project), phases, refs)

    %{
      st: st,
      job: job,
      label: label,
      sub: sub,
      latest: latest,
      where: where(project, refs),
      chats: length(phases),
      prs: Enum.count(Chats.list(project.id), & &1.pr_url)
    }
  end

  # The row's tone, its peon's job, a label and the line under it: the peon
  # builds while the project works, waves a flag while it waits on a person,
  # raises a red one when something is broken and naps when all is done.
  defp status(tile, phases, refs) do
    working = Enum.count(phases, &(&1 == "working"))

    case tile do
      %{"label" => "starting"} ->
        {"working", "build", "starting", "setting up"}

      %{"state" => "working"} when working > 0 ->
        {"working", "build", "working", "#{count(working, "chat")} working"}

      %{"state" => "working"} ->
        {"working", "build", "checking", "main runs its checks"}

      %{"state" => "stopped"} ->
        {"need", "need", "stopped", "restart it from ⋯"}

      %{"label" => "ready to ship"} ->
        {"waiting", "wave", "ready to ship", "staging ##{refs["staging"]} is ahead of prod"}

      %{"label" => "new"} ->
        {"idle", "nap", "new", "nothing built yet"}

      %{"state" => "waiting"} ->
        cond do
          "failed" in phases -> {"need", "need", "needs you", "checks failed"}
          "staged" in phases -> {"waiting", "wave", "on staging", "ship it to prod"}
          "ready" in phases -> {"waiting", "wave", "pull request open", "waiting for review"}
          true -> {"need", "need", "needs you", "a secret is missing"}
        end

      %{"label" => label} ->
        {"idle", "nap", label, "nothing open"}
    end
  end

  # "main #3 · staging #3 · prod #2"; a repo project's repo instead.
  defp where(project, refs) do
    if Project.repo?(project) do
      project.repo_url
      |> String.replace(~r{\Ahttps?://(www\.)?(github\.com/)?}, "")
      |> String.trim_trailing(".git")
    else
      Enum.map_join(~w(main staging prod), " · ", fn ref ->
        if refs[ref], do: "#{ref} ##{refs[ref]}", else: "#{ref} —"
      end)
    end
  end

  # Who the owner can hand the project to: the others in its team.
  defp teammates(%Project{team: %Burrow.Teams.Team{} = team, user_id: owner_id}),
    do: for(m <- Teams.members(team), m.user_id != owner_id, do: m.user)

  defp teammates(_), do: []

  defp new_form(attrs \\ %{}), do: to_form(Projects.change(attrs), as: "project")

  defp project!(socket, id), do: Projects.get!(socket.assigns.current_scope, id)

  # "New project" from elsewhere (the drawer on Chats) opens the form.
  @impl true
  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       if(Map.has_key?(params, "new"), do: assign(socket, creating: true), else: socket)}

  @impl true
  def handle_event("new_project", _params, socket), do: {:noreply, assign(socket, creating: true)}

  # The drawer lists a project's chats, or the general chats.
  def handle_event("peek", %{"place" => place}, socket),
    do: {:noreply, Peek.pick(socket, place, nil)}

  def handle_event("close_dialog", _params, socket),
    do: {:noreply, assign(socket, creating: false, form: new_form(), slug: nil, dialog: nil)}

  def handle_event("cancel_new", _params, socket),
    do: {:noreply, assign(socket, creating: false, form: new_form(), slug: nil)}

  def handle_event("validate", %{"project" => attrs}, socket) do
    form = attrs |> Projects.change() |> Map.put(:action, :validate) |> to_form(as: "project")
    slug = if String.trim(attrs["name"] || "") != "", do: Projects.slug_base(attrs["name"])
    {:noreply, assign(socket, form: form, slug: slug)}
  end

  def handle_event("create", %{"project" => attrs}, socket) do
    case Projects.create(socket.assigns.current_scope, attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Creating #{project.name}. It starts in a few seconds.")
         |> assign(form: new_form(), slug: nil, creating: false)
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "project"))}
    end
  end

  def handle_event("menu", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, update(socket, :menu, &if(&1 == id, do: nil, else: id))}
  end

  def handle_event("close_menu", _params, socket), do: {:noreply, assign(socket, menu: nil)}

  def handle_event("dialog", %{"dialog" => kind, "id" => id}, socket)
      when kind in ["share", "hand_over"] do
    project = project!(socket, id)

    dialog = %{
      kind: String.to_existing_atom(kind),
      project: project,
      form: to_form(%{"team_id" => project.team_id}, as: "share"),
      teammates: teammates(project)
    }

    {:noreply, assign(socket, dialog: dialog, menu: nil)}
  end

  def handle_event("hand_over", %{"hand_over" => %{"user_id" => user_id}}, socket) do
    project = socket.assigns.dialog.project

    case Projects.hand_over(socket.assigns.current_scope, project, user_id) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{project.name} now belongs to #{project.user.email}. Its chats restart on their AI login."
         )
         |> assign(dialog: nil)
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Pick someone in the project's team.")}
    end
  end

  def handle_event("share", %{"share" => %{"team_id" => team_id}}, socket) do
    project = socket.assigns.dialog.project

    case Projects.share(socket.assigns.current_scope, project, team_id) do
      {:ok, %Project{team: nil}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{project.name} is private now.")
         |> assign(dialog: nil)
         |> load()}

      {:ok, %Project{team: team}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{project.name} is shared with #{team.name}.")
         |> assign(dialog: nil)
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can share it.")}
    end
  end

  def handle_event("restart", %{"id" => id}, socket) do
    Cell.restart(project!(socket, id).id)
    {:noreply, assign(socket, menu: nil)}
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    socket = assign(socket, menu: nil)

    case Projects.delete(socket.assigns.current_scope, project!(socket, id)) do
      {:ok, project} ->
        {:noreply, socket |> put_flash(:info, "#{project.name} is deleted.") |> load()}

      {:error, :not_owner} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can delete it.")}
    end
  end

  @impl true
  def handle_async(:ai, {:ok, connected?}, socket),
    do: {:noreply, assign(socket, ai_connected: connected?)}

  def handle_async(:ai, {:exit, _}, socket), do: {:noreply, assign(socket, ai_connected: false)}

  @impl true
  def handle_info({:cell, id, _status}, socket) do
    case Enum.find(socket.assigns.projects, &(&1.id == id)) do
      nil -> {:noreply, socket}
      project -> {:noreply, update(socket, :cards, &Map.put(&1, id, card(project)))}
    end
  end

  def handle_info(:rail_changed, socket), do: {:noreply, load(socket)}

  def handle_info({event, _}, socket)
      when event in [:project_created, :project_updated, :project_deleted, :team_changed],
      do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="ws-root pr-root">
      <div
        class="ws-scrim"
        aria-hidden="true"
        data-kb-dismiss
        phx-click={JS.remove_class("show-drawer", to: ".ws-root")}
      >
      </div>
      <nav id="drawer" class="drawer" aria-label="Chats and projects" data-kb-zoom-hide>
        <div class="dlist">
          <.all_projects current />
          <.peek_list :if={@peek} peek={@peek} />
          <.account_menu user={@current_scope.user} />
        </div>
        <div class="dswitch">
          <.place_switch
            rail={@rail}
            shown={@peek && @peek.id}
            back={JS.remove_class("switching", to: "#drawer")}
            new_project={JS.remove_class("show-drawer", to: ".ws-root") |> JS.push("new_project")}
          />
        </div>
      </nav>
      <.rail new_chat={show_start()} user={@current_scope.user} home? />
      <div id="start-chat" class="startw" style="display: none">
        <div class="start-scrim" aria-hidden="true" phx-click={hide_start()}></div>
        <div
          class="pop start"
          role="dialog"
          aria-label="Start a chat"
          phx-window-keydown={hide_start()}
          phx-key="Escape"
        >
          <div class="grab" aria-hidden="true"></div>
          <div class="h">Start a chat in</div>
          <.link navigate={~p"/chats"} class="mi">
            <span class="sav"><.icon name="hero-chat-bubble-bottom-center" class="size-[18px]" /></span>
            <span class="pn"><span>Chats</span><span class="mm">No project · ask, search, think</span></span>
          </.link>
          <.link :for={p <- @projects} navigate={~p"/projects/#{p.id}/c/new"} class="mi">
            <span class="sav ini">{String.upcase(String.first(p.name))}</span>
            <span class="flex-1 truncate">{p.name}</span>
          </.link>
          <div class="msep" role="separator"></div>
          <button type="button" class="mi" phx-click={hide_start() |> JS.push("new_project")}>
            <.icon name="hero-plus" class="size-5" /><span class="flex-1">New project</span>
          </button>
        </div>
      </div>
      <main class="pr-main">
        <header class="pr-bar">
          <button
            type="button"
            class="icon-btn"
            aria-label="Chats and projects"
            phx-click={JS.add_class("show-drawer", to: ".ws-root")}
          >
            <.icon name="hero-bars-2" class="size-5" />
          </button>
          <button
            type="button"
            class="icon-btn"
            aria-label="New chat"
            aria-haspopup="dialog"
            phx-click={show_start()}
          >
            <.icon name="hero-plus" class="size-5" />
          </button>
        </header>
        <div class="pr-in">
          <div class="pr-head">
            <div class="min-w-0 flex-1">
              <h1>Projects</h1>
              <p :if={@projects != []}>{summary(@projects, @cards)}</p>
            </div>
            <button
              id="new-project"
              type="button"
              phx-click="new_project"
              data-kb-key="c"
              data-kb-label="New project"
              data-kb-group="Project"
              class="chip fill pr-new"
            >
              <.icon name="hero-plus" class="size-4" /><span>New project</span>
            </button>
          </div>

          <.modal :if={@creating} id="new-project-dialog" title="New project" return_to="new-project">
            <.form
              for={@form}
              id="project_form"
              phx-change="validate"
              phx-submit="create"
              class="flex flex-col gap-3"
            >
              <div class="min-w-0">
                <.input
                  field={@form[:name]}
                  label="Name"
                  class="field"
                  placeholder="Sauna booking"
                  autocomplete="off"
                  phx-mounted={JS.focus()}
                  hint={"slug: #{@slug || "…"}"}
                />
              </div>
              <div class="min-w-0">
                <.input
                  field={@form[:repo_url]}
                  label="From a git repo (optional)"
                  class="field"
                  placeholder="https://github.com/you/app.git"
                  autocomplete="off"
                  hint="needs .peon/preview.json for a preview"
                />
              </div>
              <div :if={!blank?(@form[:repo_url].value)} class="min-w-0">
                <.input
                  field={@form[:github_token]}
                  type="password"
                  label="GitHub token (optional for public repos)"
                  class="field"
                  autocomplete="off"
                  hint="fine-grained, for this repo: Contents and Pull requests, read and write"
                />
              </div>
              <div :if={blank?(@form[:repo_url].value)} class="min-w-0">
                <.input field={@form[:auth]} type="select" label="Login" options={Project.auths()} />
              </div>
              <div
                :if={blank?(@form[:repo_url].value) and @form[:auth].value == "accounts"}
                class="min-w-0"
              >
                <.input field={@form[:signups]} type="checkbox" label="Allow sign-ups" />
                <p class="hint">Off: the first account is the admin and adds everyone else.</p>
              </div>
              <div
                :if={blank?(@form[:repo_url].value) and @form[:auth].value == "basic"}
                class="flex flex-col gap-3"
              >
                <div class="min-w-0">
                  <.input
                    field={@form[:basic_username]}
                    label="Username"
                    class="field"
                    autocomplete="off"
                  />
                </div>
                <div class="min-w-0">
                  <.input
                    field={@form[:basic_password]}
                    type="password"
                    label="Password"
                    class="field"
                    autocomplete="new-password"
                    hint="at least 8 characters; kept as the app's secrets, not in Burrow"
                  />
                </div>
              </div>
              <div :if={@teams != []} class="min-w-0">
                <.input
                  field={@form[:team_id]}
                  type="select"
                  label="Shared with"
                  options={[{"Only me", ""} | Enum.map(@teams, &{&1.name, &1.id})]}
                />
              </div>
              <div class="flex gap-2 justify-end">
                <.button variant="primary" class="btn btn-primary" phx-disable-with="Creating…">
                  Create
                </.button>
                <button
                  type="button"
                  phx-click="cancel_new"
                  class="btn btn-ghost"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </.modal>

          <.modal
            :if={@dialog}
            id="project-dialog"
            title={"#{if @dialog.kind == :share, do: "Share", else: "Hand over"} #{@dialog.project.name}"}
            return_to={"project-menu-#{@dialog.project.id}"}
          >
            <.form
              :if={@dialog.kind == :share}
              for={@dialog.form}
              id="share-form"
              phx-change="share"
              class="flex flex-col gap-3"
            >
              <.input
                field={@dialog.form[:team_id]}
                type="select"
                label="Who can see this project"
                options={[{"Only me", ""} | Enum.map(@teams, &{&1.name, &1.id})]}
              />
              <p :if={@teams == []} class="hint m-0">
                To share it, <.link navigate={~p"/teams"}>make a team</.link> first.
              </p>
              <div class="flex justify-end">
                <button type="button" class="btn btn-ghost" phx-click="close_dialog">Close</button>
              </div>
            </.form>
            <.form
              :if={@dialog.kind == :hand_over}
              for={%{}}
              as={:hand_over}
              id="hand-over-form"
              phx-submit="hand_over"
              data-confirm="Hand this project over? It will run on their AI login, and only they can share it or hand it on."
              class="flex flex-col gap-3"
            >
              <.input
                :if={@dialog.teammates != []}
                name="hand_over[user_id]"
                value=""
                type="select"
                label="Hand it over to"
                options={Enum.map(@dialog.teammates, &{&1.email, &1.id})}
              />
              <p :if={@dialog.teammates == []} class="hint m-0">
                No one else is in {@dialog.project.team.name} yet.
              </p>
              <div class="flex gap-2 justify-end">
                <.button :if={@dialog.teammates != []} class="btn btn-secondary">Hand over</.button>
                <button type="button" class="btn btn-ghost" phx-click="close_dialog">Cancel</button>
              </div>
            </.form>
          </.modal>

          <div :if={@ai_connected == false} id="ai-missing" class="notice warn">
            <span class="st warn"><span class="dot"></span>No AI login</span>
            <span class="text-[var(--text-2)]">Connect an AI provider so Peon can work.</span>
            <.link navigate={~p"/ai"} class="btn btn-secondary btn-sm ml-auto">Connect</.link>
          </div>

          <p :if={@projects == []} class="m-0 text-[15px] text-[var(--text-2)]">
            Name your first project. It starts in a few seconds; then open its workspace and describe what to build.
          </p>

          <div :if={@projects != []} class="phead" aria-hidden="true">
            <span></span><span>Project</span><span class="hide-s">Current change</span><span class="hide-s">Status</span><span class="hide-s">Chats</span><span></span>
          </div>
          <ul :if={@projects != []} id="projects" aria-label="Projects" class="projs">
            <li :for={p <- @projects} id={"project-#{p.id}"} class="drow">
              <% c = @cards[p.id] %>
              <% owner? = Projects.owner?(@current_scope, p) %>
              <canvas
                id={"peon-mini-#{p.id}"}
                class="mini"
                phx-hook=".PeonMini"
                phx-update="ignore"
                data-job={c.job}
                width="144"
                height="34"
                aria-hidden="true"
              ></canvas>
              <div class="min-w-0 flex flex-col gap-0.5">
                <.link
                  navigate={~p"/projects/#{p.id}"}
                  data-kb="item"
                  class="nm"
                  aria-label={"#{p.name}, #{c.label}, #{c.sub}"}
                >
                  {p.name}
                </.link>
                <span class={["state ps", c.st]}><span class="dot"></span>{c.label}</span>
                <span class="pline">
                  <span :if={c.st == "working"} class="lbl working"><span class="dot"></span>{c.sub}</span><span
                    :if={c.st == "working"}
                    aria-hidden="true"
                  >·</span><span class="sub mono">{meta(p, owner?)}</span>
                </span>
              </div>
              <div class="hide-s min-w-0 flex flex-col gap-0.5">
                <span class={["chg", !c.latest && "none"]}>
                  <%= cond do %>
                    <% c.latest -> %>
                      <b>#{c.latest.id}</b>{c.latest.intent}
                    <% Project.repo?(p) -> %>
                      {if c.prs == 0, do: "No pull requests yet", else: count(c.prs, "pull request")}
                    <% true -> %>
                      Nothing built yet
                  <% end %>
                </span>
                <span class="sub mono c5">{c.where}</span>
              </div>
              <div class="hide-s min-w-0 flex flex-col gap-0.5">
                <span class={["state", c.st]}><span class="dot"></span>{c.label}</span>
                <span class="sub mono">{c.sub}</span>
              </div>
              <span class="hide-s ch c6">{count(c.chats, "chat")}</span>
              <div class="menuw" phx-click-away={@menu == p.id && "close_menu"}>
                <button
                  id={"project-menu-#{p.id}"}
                  type="button"
                  class="icon-btn"
                  aria-label={"More for #{p.name}"}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@menu == p.id)}
                  phx-click="menu"
                  phx-value-id={p.id}
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-5" />
                </button>
                <div
                  :if={@menu == p.id}
                  id={"project-menu-items-#{p.id}"}
                  class="menu"
                  role="menu"
                  aria-label={p.name}
                  phx-window-keydown="close_menu"
                  phx-key="Escape"
                >
                  <button type="button" role="menuitem" phx-click="restart" phx-value-id={p.id}>
                    Restart <.icon name="hero-arrow-path" class="size-4 text-[var(--text-3)]" />
                  </button>
                  <button
                    :if={owner?}
                    type="button"
                    role="menuitem"
                    phx-click="dialog"
                    phx-value-dialog="share"
                    phx-value-id={p.id}
                  >
                    Share <span class="k">{if p.team, do: p.team.name, else: "Only me"}</span>
                  </button>
                  <button
                    :if={owner? && p.team}
                    type="button"
                    role="menuitem"
                    phx-click="dialog"
                    phx-value-dialog="hand_over"
                    phx-value-id={p.id}
                  >
                    Hand over
                  </button>
                  <div :if={owner?} class="msep" role="separator"></div>
                  <button
                    :if={owner?}
                    id={"delete-project-#{p.id}"}
                    type="button"
                    role="menuitem"
                    class="danger"
                    phx-click="delete_project"
                    phx-value-id={p.id}
                    data-confirm={"Delete #{p.name} for good? Its chats, code history, environments and secrets go with it."}
                  >
                    Delete project
                  </button>
                </div>
              </div>
            </li>
          </ul>

          <div class="h pr-sec">No project</div>
          <div id="no-project" class="pcard">
            <div class="pchead">
              <span class="av"><.icon name="hero-chat-bubble-bottom-center" class="size-[18px]" /></span>
              <button type="button" class="pcn" phx-click={peek("chats")}>
                <span class="pct">Chats</span><span class="mm">Ask, search, think · no project</span>
              </button>
              <.link navigate={~p"/chats"} class="chip" aria-label="New chat without a project">
                <.icon name="hero-plus" class="size-5" /><span class="cl">New chat</span>
              </.link>
            </div>
            <.link :for={c <- @recent} navigate={~p"/chats/#{c.id}"} class="grow">
              <span class="gt">{ChatsLive.title(c)}</span>
              <span class="mono gm">{ChatsLive.sub(c, false)}</span>
            </.link>
            <button type="button" class="plnk" phx-click={peek("chats")}>
              All chats <.icon name="hero-chevron-right" class="size-3.5" />
            </button>
          </div>
        </div>
      </main>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PeonMini">
      export default {
        mounted() { this.stop = peonMini(this.el) },
        destroyed() { this.stop() }
      }

      // One peon and one prop, in pixels, per the UI kit's board 3c. The job
      // comes in as data-job, which LiveView keeps updating on this ignored
      // element: build hammers a hut that grows, wave holds up an amber flag
      // (waiting on you), need a red flag and "!", nap sits with z's.
      function peonMini(canvas) {
        const W = 72, H = 17, S = 2, GY = 16;
        canvas.width = W * S;
        canvas.height = H * S;
        const ctx = canvas.getContext("2d");
        ctx.imageSmoothingEnabled = false;
        const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        let col = {};
        const readCols = () => {
          const cs = getComputedStyle(canvas);
          const v = (n) => cs.getPropertyValue(n).trim();
          col = { rock: v("--border-strong"), rock2: v("--text-3"), warn: v("--warn"), err: v("--err") };
        };
        readCols();
        const G = "#8FBF5A", GD = "#6E9B3D", EYE = "#1C2412", TUSK = "#F7F4EA", BARK = "#7A4E2D",
          BARK2 = "#9A6A40", MUD = "#A07850", STEEL = "#C9CED6", SPARK = "#FFF4CC", DOOR = "#1C1612";
        const px = (x, y, w, h, c) => { ctx.fillStyle = c; ctx.fillRect(Math.round(x), Math.round(y), w, h) };
        let frame = Math.floor(Math.random() * 200), raf = 0;
        const peon = (x, lift, dir, sit) => {
          const sx = Math.round(x - 4), sy = GY - 9 - lift + (sit ? 1 : 0);
          px(sx + 1, sy, 6, 1, G); px(sx, sy + 1, 8, 6, G); px(sx + 1, sy + 7, 6, 1, G); px(sx, sy + 6, 8, 1, GD);
          const f = dir > 0 ? 1 : 0, a = sx + 1 + f, b = sx + 5 + f;
          if (sit) { px(a, sy + 3, 2, 1, EYE); px(b - 1, sy + 3, 2, 1, EYE) } else { px(a, sy + 2, 1, 1, EYE); px(b, sy + 2, 1, 1, EYE) }
          px(a, sy + 5, 1, 2, TUSK); px(b, sy + 5, 1, 2, TUSK);
          if (!sit) { px(sx + 2, sy + 8, 1, 1, EYE); px(sx + 5, sy + 8, 1, 1, EYE) }
          return { sx, sy };
        };
        const draw = () => {
          const job = canvas.dataset.job;
          ctx.setTransform(S, 0, 0, S, 0, 0);
          ctx.clearRect(0, 0, W, H);
          px(0, GY, W, 1, col.rock);
          if (job === "build") {
            const stage = 1 + Math.floor(frame / 180) % 4, x0 = 34;
            px(x0, GY - 2, 26, 2, col.rock);
            if (stage >= 2) px(x0 + 2, GY - 6, 22, 4, MUD);
            if (stage >= 3) px(x0 + 2, GY - 10, 22, 4, MUD);
            if (stage >= 4) for (let i = 0; i < 6; i++) { px(x0 + 1 + i * 2, GY - 11 - i, 2, 1, BARK); px(x0 + 23 - i * 2, GY - 11 - i, 2, 1, BARK) }
            px(x0 - 2, GY - 12, 1, 12, BARK); px(x0 - 2, GY - 9, 4, 1, BARK2);
            const { sx, sy } = peon(24, 0, 1);
            if (frame % 16 < 8) { px(sx + 8, sy + 1, 1, 3, BARK); px(sx + 7, sy, 3, 1, STEEL) }
            else { px(sx + 8, sy + 3, 3, 1, BARK); px(sx + 10, sy + 2, 1, 3, STEEL); if (frame % 16 < 11) px(sx + 12, sy + 1, 1, 1, SPARK) }
          } else if (job === "wave" || job === "need") {
            const c = job === "need" ? col.err : col.warn;
            const { sx, sy } = peon(30, job === "need" && frame % 40 < 6 ? 1 : 0, 1);
            px(sx + 8, sy - 6, 1, 11, BARK);
            const w = (frame >> 4) % 2;
            px(sx + 9, sy - 6, 5, 3, c); px(sx + 14, sy - 5 + w, 1, 2, c);
            if (job === "need") { px(sx + 3, sy - 7, 2, 4, c); px(sx + 3, sy - 2, 2, 1, c) }
            px(48, GY - 8, 14, 8, MUD); px(53, GY - 5, 4, 5, DOOR);
          } else {
            px(46, GY - 8, 14, 8, MUD); px(51, GY - 5, 4, 5, DOOR);
            const { sx, sy } = peon(30, 0, 1, true);
            const t = frame % 150;
            if (t < 70) { const zx = sx + 8 + Math.floor(t / 24), zy = sy - 1 - Math.floor(t / 14); px(zx, zy, 3, 1, col.rock2); px(zx + 1, zy + 1, 1, 1, col.rock2); px(zx, zy + 2, 3, 1, col.rock2) }
          }
        };
        const tick = () => {
          frame += 1;
          if (frame % 120 === 0) readCols();
          draw();
          raf = requestAnimationFrame(tick);
        };
        if (reduce) draw(); else raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
      }
    </script>
    """
  end

  # "2 projects · both waiting on you"
  defp summary(projects, cards) do
    n = length(projects)
    waiting = Enum.count(cards, fn {_id, c} -> c.st in ~w(waiting need) end)
    working = Enum.count(cards, fn {_id, c} -> c.st == "working" end)

    rest =
      cond do
        n == 2 and waiting == 2 -> "both waiting on you"
        n > 2 and waiting == n -> "all waiting on you"
        waiting > 0 -> "#{waiting} waiting on you"
        working > 0 -> "#{working} working"
        true -> "all quiet"
      end

    "#{count(n, "project")} · #{rest}"
  end

  defp blank?(value), do: value in [nil, ""] or String.trim(to_string(value)) == ""

  # "staging · prod · private", "staging · prod · shared · Ops", "git repo · by mira@…"
  defp meta(project, owner?) do
    envs = if Project.repo?(project), do: "git repo", else: "staging · prod"

    who =
      cond do
        !owner? -> "by #{project.user.email}"
        project.team -> "shared · #{project.team.name}"
        true -> "private"
      end

    "#{envs} · #{who}"
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
