defmodule BurrowWeb.ProjectLive.Index do
  use BurrowWeb, :live_view

  alias Burrow.{Cell, Projects}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Cell.subscribe()
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(projects: Projects.list(scope), form: to_form(Projects.change(), as: "project"))
     |> assign(ai_connected: nil)
     |> assign_statuses()
     |> start_async(:ai, fn -> Burrow.OpenCode.connected?(scope.user.id) end)}
  end

  @impl true
  def handle_event("validate", %{"project" => attrs}, socket) do
    form = Projects.change(attrs) |> Map.put(:action, :validate) |> to_form(as: "project")
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("create", %{"project" => attrs}, socket) do
    scope = socket.assigns.current_scope

    case Projects.create(scope, attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Creating #{project.name}. Its Peon starts in a few seconds.")
         |> assign(
           projects: Projects.list(scope),
           form: to_form(Projects.change(), as: "project")
         )
         |> assign_statuses()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "project"))}
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
  def handle_info({:cell, _id, _status}, socket), do: {:noreply, assign_statuses(socket)}

  defp assign_statuses(socket) do
    statuses = Map.new(socket.assigns.projects, &{&1.id, Cell.status(&1.id)})
    assign(socket, statuses: statuses)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Your projects
        <:subtitle>
          Each project has its own Peon: chat with it to build and change your app.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/ai"} class="btn btn-sm btn-ghost">AI login</.link>
        </:actions>
      </.header>

      <div :if={@ai_connected == false} id="ai-missing" class="alert alert-warning text-sm mb-4">
        Connect an AI provider first, so your Peons can work.
        <.link navigate={~p"/ai"} class="btn btn-sm">Connect</.link>
      </div>

      <.form
        for={@form}
        id="project_form"
        phx-change="validate"
        phx-submit="create"
        class="flex gap-2 items-end"
      >
        <div class="flex-1">
          <.input field={@form[:name]} label="New project" placeholder="Sauna Booking" />
        </div>
        <.button class="btn btn-primary mb-2" phx-disable-with="Creating…">Create</.button>
      </.form>

      <div id="projects" class="mt-6 space-y-3">
        <p :if={@projects == []} class="text-sm opacity-70">No projects yet.</p>
        <div :for={p <- @projects} id={"project-#{p.id}"} class="card bg-base-200">
          <div class="card-body flex-row items-center gap-4 py-4">
            <div class="flex-1">
              <div class="font-semibold">{p.name}</div>
              <div class="text-xs opacity-60">{p.slug} · Peon on port {p.port}</div>
            </div>
            <span class={["badge", badge(@statuses[p.id])]}>{status_text(@statuses[p.id])}</span>
            <.link
              :if={@statuses[p.id] == :running}
              href={~p"/projects/#{p.id}/open"}
              target="_blank"
              class="btn btn-sm btn-primary"
            >
              Open
            </.link>
            <button
              phx-click="restart"
              phx-value-id={p.id}
              class="btn btn-sm btn-ghost"
              title="Restart Peon"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp badge(:running), do: "badge-success"
  defp badge(:starting), do: "badge-warning"
  defp badge(_), do: "badge-error"

  defp status_text({:exited, code}), do: "exited (#{code})"
  defp status_text(status), do: to_string(status)
end
