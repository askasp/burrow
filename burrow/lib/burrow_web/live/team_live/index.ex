defmodule BurrowWeb.TeamLive.Index do
  @moduledoc """
  Teams: the ones you are in on the left, the selected one (`?t=<id>`) on the
  right with its members and the projects shared with it. Owners add people by
  the email they registered with.
  """

  use BurrowWeb, :live_view

  alias Burrow.{Projects, Teams}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Teams.subscribe()
      Projects.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: "Teams", form: to_form(Teams.change(), as: "team"))
     |> assign(member_form: member_form())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> assign(selected_id: params["t"]) |> select()}

  defp load(socket) do
    scope = socket.assigns.current_scope
    teams = Teams.list(scope)

    socket
    |> assign(teams: teams, member_counts: Map.new(teams, &{&1.id, length(Teams.members(&1))}))
    |> assign(projects: Projects.list(scope))
    |> select()
  end

  defp select(socket) do
    %{teams: teams, current_scope: scope} = socket.assigns
    id = socket.assigns[:selected_id]
    selected = Enum.find(teams, &(to_string(&1.id) == id)) || List.first(teams)

    if selected do
      assign(socket,
        selected: selected,
        members: Teams.members(selected),
        owner?: Teams.owner?(scope, selected),
        shared: Enum.filter(socket.assigns.projects, &(&1.team_id == selected.id))
      )
    else
      assign(socket, selected: nil, members: [], owner?: false, shared: [])
    end
  end

  defp member_form, do: to_form(%{"email" => ""}, as: "member")

  @impl true
  def handle_event("validate", %{"team" => attrs}, socket) do
    form = attrs |> Teams.change() |> Map.put(:action, :validate) |> to_form(as: "team")
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("create", %{"team" => attrs}, socket) do
    case Teams.create(socket.assigns.current_scope, attrs) do
      {:ok, team} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{team.name} is ready. Add people by their email.")
         |> assign(form: to_form(Teams.change(), as: "team"))
         |> load()
         |> push_patch(to: ~p"/teams?t=#{team.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "team"))}
    end
  end

  def handle_event("add_member", %{"member" => %{"email" => email}}, socket) do
    %{current_scope: scope, selected: team} = socket.assigns

    case Teams.add_member(scope, team, email) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added #{String.trim(email)} to #{team.name}.")
         |> assign(member_form: member_form())
         |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, add_error(reason, email))
         |> assign(member_form: to_form(%{"email" => email}, as: "member"))}
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    %{current_scope: scope, selected: team} = socket.assigns
    user_id = String.to_integer(user_id)
    leaving? = user_id == scope.user.id

    case Teams.remove_member(scope, team, user_id) do
      :ok when leaving? ->
        {:noreply,
         socket
         |> put_flash(:info, "You left #{team.name}.")
         |> load()
         |> push_patch(to: ~p"/teams")}

      :ok ->
        {:noreply, socket |> put_flash(:info, "Removed from #{team.name}.") |> load()}

      {:error, :last_owner} ->
        {:noreply,
         put_flash(socket, :error, "You are #{team.name}'s only owner, so you can't leave it.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only the team's owners can remove people.")}
    end
  end

  # The last owner can't leave, so they get no Leave button.
  defp last_owner?(members, %{role: "owner"}), do: Enum.count(members, &(&1.role == "owner")) == 1
  defp last_owner?(_members, _member), do: false

  defp add_error(:no_user, email),
    do: "No one has registered as #{String.trim(email)}. Ask them to create an account first."

  defp add_error(:already_member, email), do: "#{String.trim(email)} is already in the team."
  defp add_error(:not_owner, _email), do: "Only the team's owners can add people."

  @impl true
  def handle_info({event, _}, socket)
      when event in [:team_changed, :project_created, :project_updated],
      do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:teams}>
      <div class="flex items-start justify-between gap-5 flex-wrap">
        <div class="flex flex-col gap-1">
          <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">Teams</h1>
          <p class="m-0 text-[15px] text-[var(--text-2)]">
            Share projects with a team so everyone in it can open them.
          </p>
        </div>
        <.form
          for={@form}
          id="team_form"
          phx-change="validate"
          phx-submit="create"
          class="flex gap-2 items-start flex-[0_1_420px]"
        >
          <div class="flex-1 min-w-0">
            <.input
              field={@form[:name]}
              label="New team name"
              placeholder="Ops"
              autocomplete="off"
            />
          </div>
          <.button variant="primary" class="btn btn-primary mt-[27px]" phx-disable-with="Creating…">
            Create
          </.button>
        </.form>
      </div>

      <div class="flex flex-wrap gap-12 items-start">
        <ul id="teams" aria-label="Your teams" class="plist flex-[1_1_340px] max-w-[420px]">
          <li :if={@teams == []} class="py-4 text-sm text-[var(--text-3)]">
            You are not in a team yet.
          </li>
          <li :for={t <- @teams} id={"team-#{t.id}"}>
            <.link
              patch={~p"/teams?t=#{t.id}"}
              class={["prow", @selected && @selected.id == t.id && "sel"]}
              aria-current={@selected && @selected.id == t.id && "true"}
            >
              <span class="r1">
                <span class="name">{t.name}</span>
                <span class="mono text-[12px] text-[var(--text-3)]">
                  {@member_counts[t.id]} {if @member_counts[t.id] == 1,
                    do: "member",
                    else: "members"}
                </span>
              </span>
              <span class="r2 mono">
                <span>
                  shared projects <b>{Enum.count(@projects, &(&1.team_id == t.id))}</b>
                </span>
              </span>
            </.link>
          </li>
        </ul>

        <section
          :if={@selected}
          id="selected-team"
          aria-label="Selected team"
          class="flex-[999_1_560px] min-w-0 flex flex-col gap-8"
        >
          <div class="flex flex-col gap-0.5">
            <h2 class="m-0 text-2xl leading-8 font-semibold tracking-[-0.01em]">{@selected.name}</h2>
            <span class="text-[13px] text-[var(--text-3)]">
              {if @owner?, do: "You own this team.", else: "You are a member."}
            </span>
          </div>

          <div>
            <div class="sec-h"><span class="eyebrow">Members</span></div>
            <ul id="members" class="rows">
              <li :for={m <- @members} id={"member-#{m.user_id}"}>
                <span class="flex-1 min-w-0 truncate">{m.user.email}</span>
                <span :if={m.role == "owner"} class="tag">owner</span>
                <button
                  :if={m.user_id == @current_scope.user.id and not last_owner?(@members, m)}
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="remove_member"
                  phx-value-user-id={m.user_id}
                  data-confirm={"Leave #{@selected.name}? Your projects in it become private."}
                >
                  Leave
                </button>
                <button
                  :if={@owner? and m.user_id != @current_scope.user.id}
                  type="button"
                  class="icon-btn sm"
                  aria-label={"Remove #{m.user.email}"}
                  phx-click="remove_member"
                  phx-value-user-id={m.user_id}
                  data-confirm={"Remove #{m.user.email} from #{@selected.name}?"}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </li>
            </ul>
            <.form
              :if={@owner?}
              for={@member_form}
              id="member-form"
              phx-submit="add_member"
              class="flex gap-2 items-start pt-4 max-w-[480px]"
            >
              <div class="flex-1 min-w-0">
                <.input
                  field={@member_form[:email]}
                  type="email"
                  label="Add someone by email"
                  placeholder="teammate@example.com"
                  hint="They need a Peon account first."
                  required
                />
              </div>
              <.button class="btn btn-secondary mt-[27px]">Add</.button>
            </.form>
          </div>

          <div>
            <div class="sec-h"><span class="eyebrow">Shared projects</span></div>
            <ul id="shared-projects" class="rows">
              <li :if={@shared == []} class="text-[var(--text-3)]">
                None yet. Share a project from its ⋯ menu on Projects.
              </li>
              <li :for={p <- @shared}>
                <.link navigate={~p"/projects/#{p.id}"} class="flex-1 min-w-0 truncate font-medium">
                  {p.name}
                </.link>
                <span class="mono text-[12px] text-[var(--text-3)]">by {p.user.email}</span>
              </li>
            </ul>
          </div>
        </section>

        <section
          :if={!@selected}
          class="flex-[999_1_560px] min-w-0 pt-4 text-[15px] text-[var(--text-2)]"
        >
          Make a team above, add your teammates, then share projects with it.
        </section>
      </div>
    </Layouts.app>
    """
  end
end
