defmodule BurrowWeb.AppLive do
  @moduledoc """
  An internal app (`Burrow.Projects.Project.internal?/1`) full size, as the
  drawer's apps open it: its live in a frame, where Burrow logs the viewer
  in as themselves (`BurrowWeb.AppController`). The drawer lists the
  project's chats, where the app is changed.
  """

  use BurrowWeb, :live_view

  import BurrowWeb.WorkspaceLive.Components,
    only: [place_switch: 1, account_menu: 1, rail: 1, all_projects: 1, peek_list: 1]

  alias Burrow.{Activity, Env, Projects}
  alias BurrowWeb.{ChatsLive, Peek}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get!(socket.assigns.current_scope, id)

    if Projects.Project.internal?(project) do
      if connected?(socket) do
        Env.subscribe(project.id)
        Activity.subscribe()
      end

      {:ok,
       socket
       |> assign(project: project, page_title: project.name, frame_key: 0)
       |> assign(live: Env.info(project, "live"))
       |> ChatsLive.load_rail()
       |> Peek.pick(project.id, nil)}
    else
      {:ok, push_navigate(socket, to: ~p"/projects/#{project}")}
    end
  end

  @impl true
  def handle_event("peek", %{"place" => place}, socket),
    do: {:noreply, Peek.pick(socket, place, nil)}

  def handle_event("reload", _params, socket),
    do: {:noreply, update(socket, :frame_key, &(&1 + 1))}

  @impl true
  def handle_info({:env, "live", info}, socket), do: {:noreply, assign(socket, live: info)}

  def handle_info(:rail_changed, socket),
    do: {:noreply, socket |> ChatsLive.load_rail() |> Peek.reload(nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="ws-root ap-root">
      <div
        class="ws-scrim"
        aria-hidden="true"
        data-kb-dismiss
        phx-click={JS.remove_class("show-drawer", to: ".ws-root")}
      >
      </div>
      <nav id="drawer" class="drawer" aria-label="Chats and projects" data-kb-zoom-hide>
        <div class="dlist">
          <.all_projects rail={@rail} app={@project.id} />
          <.peek_list :if={@peek} peek={@peek} />
          <.account_menu user={@current_scope.user} />
        </div>
        <div class="dswitch">
          <.place_switch
            rail={@rail}
            shown={@peek && @peek.id}
            back={JS.remove_class("switching", to: "#drawer")}
            new_project={JS.navigate(~p"/projects?new")}
          />
        </div>
      </nav>
      <.rail new_chat={JS.navigate(~p"/projects/#{@project}/c/new")} user={@current_scope.user} />
      <main class="ws-main">
        <header class="pbar">
          <button
            type="button"
            class="icon-btn pbar-menu"
            aria-label="Chats and projects"
            phx-click={JS.add_class("show-drawer", to: ".ws-root")}
          >
            <.icon name="hero-bars-2" class="size-5" />
          </button>
          <div class="pbar-title">
            <span class="pbar-ttl"><span class="pbar-name pbar-t">{@project.name}</span></span>
          </div>
          <button
            :if={running?(@live)}
            type="button"
            class="icon-btn"
            aria-label="Reload"
            title="Reload"
            phx-click="reload"
          >
            <.icon name="hero-arrow-path" class="size-[17px]" />
          </button>
          <.link navigate={~p"/projects/#{@project}"} class="btn btn-secondary btn-sm">
            <.icon name="hero-wrench-screwdriver" class="size-4" /> Build
          </.link>
        </header>
        <div class="ws-prev-body">
          <iframe
            :if={running?(@live)}
            id={"app-frame-#{@frame_key}"}
            src={~p"/projects/#{@project}/app"}
            class="ws-frame"
          />
          <div :if={!running?(@live)} class="ws-prev-empty" role="status">
            <div class="ws-prev-title">{empty_text(@live)}</div>
            <.link navigate={~p"/projects/#{@project}"} class="btn btn-primary btn-sm">
              Open {@project.name}'s chats
            </.link>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # Up, also while a change loads into it; a deploy doesn't blank the frame.
  defp running?(%{deployed: id, status: status}) when id != nil,
    do: status not in [:stopped, :booting] and not match?({:crashed, _}, status)

  defp running?(_live), do: false

  defp empty_text(%{deployed: id, status: {:crashed, _}}) when id != nil, do: "It is down."
  defp empty_text(%{deployed: id}) when id != nil, do: "Starting…"
  defp empty_text(_live), do: "Not live yet. Its first merged chat puts it live."
end
