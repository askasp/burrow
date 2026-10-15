defmodule BurrowWeb.ProjectLive.Index do
  @moduledoc """
  The projects screen: your projects and those shared with your teams on the
  left, the selected one (`?p=<id>`) on the right with its Peon and who it is
  shared with.
  """

  use BurrowWeb, :live_view

  alias Burrow.{Cell, Projects, Teams}
  alias Burrow.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cell.subscribe()
      Projects.subscribe()
      Teams.subscribe()
    end

    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Projects", ai_connected: nil)
     |> assign(form: new_form(), slug: nil)
     |> load()
     |> start_async(:ai, fn -> Burrow.OpenCode.connected?(scope.user.id) end)}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> assign(selected_id: parse_id(params["p"])) |> select()}

  defp load(socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list(scope)

    socket
    |> assign(projects: projects, teams: Teams.list(scope))
    |> assign(statuses: Map.new(projects, &{&1.id, Cell.status(&1.id)}))
    |> select()
  end

  defp select(socket) do
    %{projects: projects} = socket.assigns
    id = socket.assigns[:selected_id]
    selected = Enum.find(projects, &(&1.id == id)) || List.first(projects)

    socket
    |> assign(selected: selected)
    |> assign(share_form: to_form(%{"team_id" => selected && selected.team_id}, as: "share"))
    |> assign(teammates: teammates(selected))
  end

  # Who the owner can hand the project to: the others in its team.
  defp teammates(%Project{team: %Burrow.Teams.Team{} = team, user_id: owner_id}),
    do: for(m <- Teams.members(team), m.user_id != owner_id, do: m.user)

  defp teammates(_), do: []

  defp new_form(attrs \\ %{}), do: to_form(Projects.change(attrs), as: "project")

  defp parse_id(nil), do: nil

  defp parse_id(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  @impl true
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
         |> put_flash(:info, "Creating #{project.name}. Its Peon starts in a few seconds.")
         |> assign(form: new_form(), slug: nil)
         |> load()
         |> push_patch(to: ~p"/projects?p=#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "project"))}
    end
  end

  def handle_event("hand_over", %{"hand_over" => %{"user_id" => user_id}}, socket) do
    project = socket.assigns.selected

    case Projects.hand_over(socket.assigns.current_scope, project, user_id) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{project.name} now belongs to #{project.user.email}. Its Peon restarts on their AI login."
         )
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Pick someone in the project's team.")}
    end
  end

  def handle_event("share", %{"share" => %{"team_id" => team_id}}, socket) do
    project = socket.assigns.selected

    case Projects.share(socket.assigns.current_scope, project, team_id) do
      {:ok, %Project{team: nil}} ->
        {:noreply, socket |> put_flash(:info, "#{project.name} is private now.") |> load()}

      {:ok, %Project{team: team}} ->
        {:noreply,
         socket |> put_flash(:info, "#{project.name} is shared with #{team.name}.") |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only the project's owner can share it.")}
    end
  end

  def handle_event("restart", %{"id" => id}, socket) do
    project = Projects.get!(socket.assigns.current_scope, id)
    Cell.restart(project.id)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:ai, {:ok, connected?}, socket),
    do: {:noreply, assign(socket, ai_connected: connected?)}

  def handle_async(:ai, {:exit, _}, socket), do: {:noreply, assign(socket, ai_connected: false)}

  @impl true
  def handle_info({:cell, id, status}, socket) do
    if Map.has_key?(socket.assigns.statuses, id),
      do: {:noreply, update(socket, :statuses, &Map.put(&1, id, status))},
      else: {:noreply, socket}
  end

  def handle_info({event, _}, socket)
      when event in [:project_created, :project_updated, :team_changed],
      do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div class="flex items-start justify-between gap-5 flex-wrap">
        <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">Projects</h1>
        <.form
          for={@form}
          id="project_form"
          phx-change="validate"
          phx-submit="create"
          class="flex gap-2 items-start flex-[0_1_520px] flex-wrap"
        >
          <div class="flex-1 min-w-[200px]">
            <.input
              field={@form[:name]}
              label="New project name"
              class="field"
              placeholder="Sauna booking"
              autocomplete="off"
              hint={"slug: #{@slug || "…"}"}
            />
          </div>
          <div :if={@teams != []} class="w-[160px]">
            <.input
              field={@form[:team_id]}
              type="select"
              label="Shared with"
              options={[{"Only me", ""} | Enum.map(@teams, &{&1.name, &1.id})]}
            />
          </div>
          <.button variant="primary" class="btn btn-primary mt-[27px]" phx-disable-with="Creating…">
            Create
          </.button>
        </.form>
      </div>

      <div :if={@ai_connected == false} id="ai-missing" class="notice warn">
        <span class="st warn"><span class="dot"></span>No AI login</span>
        <span class="text-[var(--text-2)]">Connect an AI provider so your Peons can work.</span>
        <.link navigate={~p"/ai"} class="btn btn-secondary btn-sm ml-auto">Connect</.link>
      </div>

      <div class="flex flex-wrap gap-12 items-start">
        <ul id="projects" aria-label="Projects" class="plist flex-[1_1_340px] max-w-[420px]">
          <li :if={@projects == []} class="py-4 text-sm text-[var(--text-3)]">No projects yet.</li>
          <li :for={p <- @projects} id={"project-#{p.id}"}>
            <.link
              patch={~p"/projects?p=#{p.id}"}
              class={["prow", @selected && @selected.id == p.id && "sel"]}
              aria-current={@selected && @selected.id == p.id && "true"}
            >
              <span class="r1">
                <span class="name">{p.name}</span>
                <.status status={@statuses[p.id]} />
              </span>
              <span class="r2 mono">
                <span>{p.slug}</span>
                <span :if={p.team}>shared · <b>{p.team.name}</b></span>
                <span :if={!p.team}>private</span>
                <span :if={p.user_id != @current_scope.user.id}>by <b>{p.user.email}</b></span>
              </span>
              <span class={["hp", tone(@statuses[p.id])]} aria-hidden="true"><i></i></span>
            </.link>
          </li>
        </ul>

        <section
          :if={@selected}
          id="selected-project"
          aria-label="Selected project"
          class="flex-[999_1_560px] min-w-0 flex flex-col gap-8"
        >
          <div class="flex items-start justify-between gap-4 flex-wrap">
            <div class="flex flex-col gap-0.5 min-w-0">
              <h2 class="m-0 text-2xl leading-8 font-semibold tracking-[-0.01em]">
                {@selected.name}
              </h2>
              <span class="mono text-[12.5px] text-[var(--text-3)]">
                {@selected.slug} · Peon on port {@selected.port}
              </span>
            </div>
            <.link
              :if={@statuses[@selected.id] == :running}
              id="open-workspace"
              href={~p"/projects/#{@selected.id}/open"}
              target="_blank"
              class="btn btn-primary"
            >
              Open workspace
            </.link>
            <button :if={@statuses[@selected.id] != :running} class="btn btn-primary" disabled>
              Open workspace
            </button>
          </div>

          <div>
            <div class="cells">
              <div class="cell">
                <div class="flex items-center gap-2.5">
                  <span class="eyebrow">peon</span>
                  <.status status={@statuses[@selected.id]} />
                </div>
                <div class="tip">:{@selected.port}<small>{@selected.preview_ports}</small></div>
                <button
                  id="restart-peon"
                  type="button"
                  class="xlink w-fit"
                  phx-click="restart"
                  phx-value-id={@selected.id}
                >
                  Restart Peon <.icon name="hero-arrow-path" class="size-3.5" />
                </button>
              </div>
              <div class="cell">
                <span class="eyebrow">sharing</span>
                <div class="tip plain">
                  {if @selected.team, do: @selected.team.name, else: "Private"}
                </div>
                <span class="meta">
                  {if @selected.team,
                    do: "Everyone in #{@selected.team.name} can open and restart it.",
                    else: "Only you can see it."}
                </span>
              </div>
            </div>
            <p class="m-0 py-3 text-[13.5px] text-[var(--text-2)]">
              <%= if Projects.owner?(@current_scope, @selected) do %>
                Runs on your AI login{if @selected.team, do: ", also when teammates chat in it"}.
              <% else %>
                Owned by {@selected.user.email}. Runs on their AI login.
              <% end %>
            </p>
          </div>

          <div :if={Projects.owner?(@current_scope, @selected)}>
            <div class="sec-h"><span class="eyebrow">Share</span></div>
            <.form
              for={@share_form}
              id="share-form"
              phx-change="share"
              class="border-t border-[var(--border-strong)] pt-4 max-w-[420px]"
            >
              <.input
                field={@share_form[:team_id]}
                type="select"
                label="Who can see this project"
                options={[{"Only me", ""} | Enum.map(@teams, &{&1.name, &1.id})]}
              />
              <p :if={@teams == []} class="hint m-0">
                To share it, <.link navigate={~p"/teams"}>make a team</.link> first.
              </p>
            </.form>
            <.form
              :if={@selected.team && @teammates != []}
              for={%{}}
              as={:hand_over}
              id="hand-over-form"
              phx-submit="hand_over"
              data-confirm="Hand this project over? It will run on their AI login, and only they can share it or hand it on."
              class="mt-4 max-w-[420px] flex gap-2 items-end"
            >
              <div class="flex-1">
                <.input
                  name="hand_over[user_id]"
                  value=""
                  type="select"
                  label="Hand it over to"
                  options={Enum.map(@teammates, &{&1.email, &1.id})}
                />
              </div>
              <.button class="btn btn-secondary btn-sm mb-1">Hand over</.button>
            </.form>
          </div>
        </section>

        <section
          :if={!@selected}
          class="flex-[999_1_560px] min-w-0 pt-4 text-[15px] text-[var(--text-2)]"
        >
          Name your first project above. Its Peon starts in a few seconds; then open its workspace and describe what to build.
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :status, :any, required: true

  defp status(assigns) do
    ~H"""
    <span class={["st", tone(@status)]}><span class="dot"></span>{status_text(@status)}</span>
    """
  end

  defp tone(:running), do: "ok"
  defp tone(:starting), do: "warn"
  defp tone({:exited, _}), do: "err"
  defp tone(_), do: "idle"

  defp status_text({:exited, code}), do: "exited (#{code})"
  defp status_text(nil), do: "stopped"
  defp status_text(status), do: to_string(status)
end
