defmodule BurrowWeb.AILive do
  @moduledoc """
  Connect the AI providers your Peons use, and pick the model. An API key you
  connected can be shared with your teams (`Burrow.TeamKeys`); keys your
  teams share with you show under their provider.
  """

  use BurrowWeb, :live_view

  alias Burrow.{Cell, OpenCode, Projects, TeamKeys, Teams}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      TeamKeys.subscribe(user.id)
      Teams.subscribe()
    end

    {:ok,
     socket
     |> assign(providers: nil, logins: [], models: %{}, model: OpenCode.model(user.id))
     |> assign(error: nil, attempt: nil, importing: false)
     |> assign(local_import?: Application.get_env(:burrow, :local_login_import, false))
     |> assign_sharing()
     |> load()}
  end

  # Brings the team keys up to date first: a key the user shared and then
  # replaced or removed is no longer shared.
  defp load(socket) do
    user_id = socket.assigns.current_scope.user.id

    start_async(socket, :load, fn ->
      TeamKeys.sync(user_id)

      with {:ok, providers} <- OpenCode.providers(user_id),
           {:ok, logins} <- OpenCode.logins(user_id),
           {:ok, models} <- OpenCode.models(user_id),
           do: {providers, logins, models}
    end)
  end

  defp assign_sharing(socket) do
    %{current_scope: scope} = socket.assigns

    assign(socket,
      teams: Teams.list(scope),
      shared: TeamKeys.shared(scope.user.id),
      team_keys: TeamKeys.available(scope.user.id)
    )
  end

  @impl true
  def handle_async(:load, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, error: "Could not reach opencode: #{inspect(reason)}")}

  def handle_async(:load, {:ok, {providers, logins, models}}, socket) do
    model = OpenCode.usable(socket.assigns.model, Enum.map(models, &elem(&1, 0)))

    {:noreply,
     socket
     |> assign(providers: providers, logins: logins, models: Map.new(models), model: model)
     |> assign(error: nil)
     |> assign_sharing()}
  end

  def handle_async(:load, {:exit, reason}, socket),
    do: {:noreply, assign(socket, error: "Could not reach opencode: #{inspect(reason)}")}

  @impl true
  def handle_event("connect_key", %{"provider" => provider, "key" => key}, socket) do
    case OpenCode.connect_key(user_id(socket), provider, String.trim(key)) do
      :ok ->
        message =
          if Map.has_key?(socket.assigns.shared, provider),
            do: "Connected. Your teams no longer get the key it replaced.",
            else: "Connected."

        {:noreply, socket |> put_flash(:info, message) |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not connect: #{describe(reason)}")}
    end
  end

  def handle_event("oauth", %{"provider" => provider, "method" => method}, socket) do
    case OpenCode.start_oauth(user_id(socket), provider, method) do
      {:ok, attempt} ->
        Process.send_after(self(), :poll_oauth, 2_000)
        {:noreply, assign(socket, attempt: attempt)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start the login: #{describe(reason)}")}
    end
  end

  def handle_event("oauth_code", %{"code" => code}, socket) do
    %{provider: provider, attempt_id: attempt_id} = socket.assigns.attempt

    case OpenCode.complete_oauth(user_id(socket), provider, attempt_id, String.trim(code)) do
      :ok ->
        {:noreply, socket |> assign(attempt: nil) |> put_flash(:info, "Connected.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "That code did not work: #{describe(reason)}")}
    end
  end

  def handle_event("cancel_oauth", _params, socket), do: {:noreply, assign(socket, attempt: nil)}

  # Your own logins for the provider, not the keys teams share with you.
  def handle_event("remove_login", %{"provider" => provider}, socket) do
    user_id = user_id(socket)

    result =
      socket.assigns.logins
      |> Enum.filter(&(&1.provider == provider and not TeamKeys.team_login?(&1)))
      |> Enum.reduce_while(:ok, fn login, :ok ->
        case OpenCode.remove_login(user_id, login.id) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    case result do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Removed.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove it: #{describe(reason)}")}
    end
  end

  # The checkbox for one of the user's teams: shares the key with it, or stops.
  def handle_event("share", %{"provider" => provider, "team" => team_id}, socket) do
    %{current_scope: scope, teams: teams, shared: shared} = socket.assigns
    team = Enum.find(teams, &(to_string(&1.id) == team_id))

    result =
      cond do
        team == nil -> {:error, :not_member}
        team.id in Map.get(shared, provider, []) -> TeamKeys.unshare(scope, provider, team.id)
        true -> TeamKeys.share(scope, provider, team.id)
      end

    socket =
      case result do
        :ok ->
          if team.id in Map.get(shared, provider, []),
            do: put_flash(socket, :info, "#{team.name} no longer gets this key."),
            else: put_flash(socket, :info, "Everyone in #{team.name} can use this key now.")

        {:error, :not_a_key} ->
          put_flash(socket, :error, "Only an API key you connected yourself can be shared.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not share it: #{describe(reason)}")
      end

    {:noreply, assign_sharing(socket)}
  end

  def handle_event("import_local", _params, socket) do
    case OpenCode.import_local_logins(user_id(socket)) do
      {:ok, []} ->
        {:noreply, put_flash(socket, :error, "This computer's opencode has no logins.")}

      {:ok, ids} ->
        {:noreply, socket |> put_flash(:info, "Imported: #{Enum.join(ids, ", ")}.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Import failed: #{describe(reason)}")}
    end
  end

  def handle_event("model", %{"model" => model}, socket) do
    user_id = user_id(socket)
    {:ok, _} = OpenCode.set_model(user_id, model)

    # Peons read the model when they start.
    for project <- Projects.owned(socket.assigns.current_scope), do: Cell.restart(project.id)

    {:noreply, socket |> assign(model: model) |> put_flash(:info, "Your Peons now use #{model}.")}
  end

  @impl true
  def handle_info({:team_keys, _user_id}, socket), do: {:noreply, load(socket)}
  def handle_info({:team_changed, _team_id}, socket), do: {:noreply, assign_sharing(socket)}

  def handle_info(:poll_oauth, %{assigns: %{attempt: nil}} = socket), do: {:noreply, socket}

  def handle_info(:poll_oauth, socket) do
    %{provider: provider, attempt_id: attempt_id} = socket.assigns.attempt

    case OpenCode.oauth_status(user_id(socket), provider, attempt_id) do
      {:ok, "pending"} ->
        Process.send_after(self(), :poll_oauth, 2_000)
        {:noreply, socket}

      {:ok, "complete"} ->
        {:noreply, socket |> assign(attempt: nil) |> put_flash(:info, "Connected.") |> load()}

      {:ok, status} ->
        {:noreply, socket |> assign(attempt: nil) |> put_flash(:error, "Login #{status}.")}

      {:error, _} ->
        Process.send_after(self(), :poll_oauth, 2_000)
        {:noreply, socket}
    end
  end

  defp user_id(socket), do: socket.assigns.current_scope.user.id

  # The user's own login the provider uses, else their latest.
  defp own_login(logins, provider) do
    own = Enum.filter(logins, &(&1.provider == provider and not TeamKeys.team_login?(&1)))
    Enum.find(own, & &1.active?) || List.last(own)
  end

  defp describe({status, %{"message" => message}}), do: "#{message} (#{status})"
  defp describe(reason), do: inspect(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:ai}>
      <.header>
        AI login
        <:subtitle>
          Your Peons run on opencode with your own subscriptions or API keys, and the keys your teams share with you. Connect at least one provider.
        </:subtitle>
      </.header>

      <div class="max-w-[760px] flex flex-col gap-8">
        <p :if={@error} class="notice err m-0">{@error}</p>
        <p
          :if={@providers == nil and @error == nil}
          class="m-0 flex items-center gap-2 text-sm text-[var(--text-3)]"
        >
          <.icon name="hero-arrow-path" class="size-4 spin" /> Loading providers…
        </p>

        <section :if={@attempt} id="oauth" aria-label="Finish signing in">
          <div class="sec-h"><span class="eyebrow">Finish signing in</span></div>
          <div class="border-t border-[var(--border-strong)] border-b border-b-[var(--border)] py-4 flex flex-col gap-3 text-sm">
            <p class="m-0 whitespace-pre-wrap text-[var(--text-2)]">{@attempt.instructions}</p>
            <a href={@attempt.url} target="_blank" class="btn btn-primary btn-sm w-fit">
              Open the sign-in page
            </a>
            <.form
              :if={@attempt.mode == "code"}
              for={%{}}
              as={:oauth}
              id="oauth-code"
              phx-submit="oauth_code"
              class="flex gap-2 max-w-[480px]"
            >
              <label for="oauth-code-input" class="sr-only">Code</label>
              <input
                id="oauth-code-input"
                name="code"
                class="field flex-1"
                placeholder="Paste the code here"
              />
              <button class="btn btn-secondary">Done</button>
            </.form>
            <p :if={@attempt.mode != "code"} class="m-0 st warn">
              <span class="dot"></span> Waiting for you to sign in…
            </p>
            <button phx-click="cancel_oauth" class="btn btn-ghost btn-sm w-fit">Cancel</button>
          </div>
        </section>

        <div :if={@local_import?} class="notice">
          <button phx-click="import_local" class="btn btn-secondary btn-sm">
            Use this computer's opencode logins
          </button>
          <span class="text-[13px] text-[var(--text-3)]">
            Local mode: copies the logins of the opencode installed here.
          </span>
        </div>

        <section :if={@providers} aria-label="Providers">
          <div class="sec-h"><span class="eyebrow">Providers</span></div>
          <ul id="providers" class="rows">
            <li
              :for={p <- @providers}
              id={"provider-#{p.id}"}
              class="flex-wrap !items-start !py-3.5"
            >
              <div class="w-[180px] flex flex-col gap-1 pt-1.5">
                <span class="font-semibold">{p.name}</span>
                <span :if={p.connected?} class="st ok"><span class="dot"></span>connected</span>
              </div>
              <div class="flex-1 min-w-[260px] flex flex-wrap gap-2 items-center">
                <button
                  :for={m <- p.oauth}
                  phx-click="oauth"
                  phx-value-provider={p.id}
                  phx-value-method={m.id}
                  class="btn btn-secondary btn-sm"
                >
                  {m.label}
                </button>
                <.form
                  :if={p.key?}
                  for={%{}}
                  as={:key}
                  phx-submit="connect_key"
                  class="flex gap-2 flex-1 min-w-[240px]"
                >
                  <input type="hidden" name="provider" value={p.id} />
                  <label for={"key-#{p.id}"} class="sr-only">{p.name} API key</label>
                  <input
                    id={"key-#{p.id}"}
                    name="key"
                    type="password"
                    autocomplete="off"
                    class="field flex-1 !h-8 !text-[13px]"
                    placeholder="API key"
                  />
                  <button class="btn btn-secondary btn-sm">Connect key</button>
                </.form>
              </div>
              <.logins
                provider={p}
                own={own_login(@logins, p.id)}
                teams={@teams}
                shared={Map.get(@shared, p.id, [])}
                team_keys={Map.get(@team_keys, p.id, [])}
                go_key?={
                  p.id == "opencode" and Enum.any?(@providers, &(&1.id == "opencode-go" and &1.key?))
                }
              />
            </li>
          </ul>
        </section>

        <section :if={@models != %{}} aria-label="Model">
          <div class="sec-h"><span class="eyebrow">Model</span></div>
          <.form
            for={%{}}
            as={:model}
            id="model-form"
            phx-change="model"
            class="border-t border-[var(--border-strong)] pt-4 max-w-[420px]"
          >
            <label for="model-select" class="label">Model for your Peons</label>
            <select id="model-select" name="model" class="field">
              <option
                :for={m <- Enum.uniq([@model | Enum.sort(Map.keys(@models))])}
                value={m}
                selected={m == @model}
              >
                {m}
              </option>
            </select>
            <p class="hint">Changing it restarts the Peons you own.</p>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :provider, :map, required: true
  attr :own, :map, doc: "the user's own login, nil for none"
  attr :teams, :list, required: true
  attr :shared, :list, required: true, doc: "ids of the teams the user's key is shared with"
  attr :team_keys, :list, required: true, doc: "keys others share with the user's teams"

  attr :go_key?, :boolean,
    default: false,
    doc: "an OpenCode Console sign-in, while OpenCode Go takes an API key"

  # Under a provider: the user's own login, the teams they share it with, and
  # the keys their teams share with them.
  defp logins(assigns) do
    ~H"""
    <div
      :if={@own || @team_keys != []}
      class="basis-full sm:pl-[192px] flex flex-col gap-2 text-[13px] text-[var(--text-2)]"
    >
      <div :if={@own} class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span>{if @own.type == "key", do: "Your API key", else: "Your sign-in"}</span>
        <button
          type="button"
          phx-click="remove_login"
          phx-value-provider={@provider.id}
          class="btn btn-ghost btn-sm"
          aria-label={"Remove your #{@provider.name} login"}
          data-confirm={
            if @shared != [],
              do: "Remove your #{@provider.name} key? Your teams lose it too.",
              else: "Remove your #{@provider.name} login?"
          }
        >
          Remove
        </button>
      </div>
      <div
        :if={@own && @own.type == "key" && @teams != []}
        id={"share-#{@provider.id}"}
        class="flex flex-col gap-1"
      >
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <span class="text-[var(--text-3)]">Share with</span>
          <label :for={t <- @teams} class="check !text-[13px]">
            <input
              type="checkbox"
              id={"share-#{@provider.id}-#{t.id}"}
              phx-click="share"
              phx-value-provider={@provider.id}
              phx-value-team={t.id}
              checked={t.id in @shared}
            />
            {t.name}
          </label>
        </div>
        <p class="hint m-0">
          Everyone in these teams can use the key in their Peons. They never see it.
        </p>
      </div>
      <p
        :if={@own && @own.type != "key" && @teams != []}
        id={"sign-in-hint-#{@provider.id}"}
        class="hint m-0"
      >
        Sign-ins can't be shared with a team, only API keys.
        <span :if={@go_key?}>
          To share your OpenCode Go subscription, copy its API key from the <a
            href="https://opencode.ai/console"
            target="_blank"
            rel="noopener"
          >OpenCode Console</a>,
          connect it under OpenCode Go, and share it there.
        </span>
      </p>
      <p :for={k <- @team_keys} id={"team-key-#{k.id}"} class="m-0">
        Team key from <b>{Enum.join(k.teams, ", ")}</b>, shared by {k.shared_by}.
        <span class="text-[var(--text-3)]">
          {if @own, do: "Your own login wins.", else: "Your Peons can use it."}
        </span>
      </p>
    </div>
    """
  end
end
