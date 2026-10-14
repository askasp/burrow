defmodule BurrowWeb.AILive do
  @moduledoc "Connect the AI providers your Peons use, and pick the model."

  use BurrowWeb, :live_view

  alias Burrow.{Cell, OpenCode, Projects}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(providers: nil, models: [], model: OpenCode.model(user.id), error: nil)
     |> assign(attempt: nil, importing: false)
     |> assign(local_import?: Application.get_env(:burrow, :local_login_import, false))
     |> load()}
  end

  defp load(socket) do
    user_id = socket.assigns.current_scope.user.id

    start_async(socket, :load, fn ->
      with {:ok, providers} <- OpenCode.providers(user_id),
           {:ok, models} <- OpenCode.models(user_id),
           do: {providers, models}
    end)
  end

  @impl true
  def handle_async(:load, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, error: "Could not reach opencode: #{inspect(reason)}")}

  def handle_async(:load, {:ok, {providers, models}}, socket),
    do: {:noreply, assign(socket, providers: providers, models: models, error: nil)}

  def handle_async(:load, {:exit, reason}, socket),
    do: {:noreply, assign(socket, error: "Could not reach opencode: #{inspect(reason)}")}

  @impl true
  def handle_event("connect_key", %{"provider" => provider, "key" => key}, socket) do
    case OpenCode.connect_key(user_id(socket), provider, String.trim(key)) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Connected.") |> load()}

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
    for project <- Projects.list(socket.assigns.current_scope), do: Cell.restart(project.id)

    {:noreply, socket |> assign(model: model) |> put_flash(:info, "Your Peons now use #{model}.")}
  end

  @impl true
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

  defp describe({status, %{"message" => message}}), do: "#{message} (#{status})"
  defp describe(reason), do: inspect(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        AI login
        <:subtitle>
          Your Peons run on opencode with your own subscriptions or API keys. Connect at least one provider.
        </:subtitle>
      </.header>

      <p :if={@error} class="alert alert-error text-sm">{@error}</p>
      <p :if={@providers == nil and @error == nil} class="text-sm opacity-70 flex items-center gap-2">
        <span class="loading loading-spinner loading-sm"></span> Loading providers…
      </p>

      <div :if={@attempt} id="oauth" class="card bg-base-200 my-4">
        <div class="card-body text-sm space-y-2">
          <p class="font-semibold">Finish signing in</p>
          <p class="whitespace-pre-wrap">{@attempt.instructions}</p>
          <a href={@attempt.url} target="_blank" class="btn btn-primary btn-sm w-fit">Open the sign-in page</a>
          <.form
            :if={@attempt.mode == "code"}
            for={%{}}
            as={:oauth}
            id="oauth-code"
            phx-submit="oauth_code"
            class="flex gap-2"
          >
            <input
              name="code"
              class="input input-bordered input-sm flex-1"
              placeholder="Paste the code here"
            />
            <button class="btn btn-sm">Done</button>
          </.form>
          <p :if={@attempt.mode != "code"} class="opacity-70 flex items-center gap-2">
            <span class="loading loading-dots loading-xs"></span> Waiting for you to sign in…
          </p>
          <button phx-click="cancel_oauth" class="link text-xs w-fit">Cancel</button>
        </div>
      </div>

      <div :if={@local_import?} class="my-4 text-sm flex items-center gap-3">
        <button phx-click="import_local" class="btn btn-sm">Use this computer's opencode logins</button>
        <span class="opacity-60">Local mode: copies the logins of the opencode installed here.</span>
      </div>

      <div :if={@providers} id="providers" class="space-y-3">
        <div :for={p <- @providers} id={"provider-#{p.id}"} class="card bg-base-200">
          <div class="card-body py-4 gap-3">
            <div class="flex items-center gap-3">
              <span class="font-semibold">{p.name}</span>
              <span :if={p.connected?} class="badge badge-success badge-sm">connected</span>
            </div>
            <div class="flex flex-wrap gap-2 items-center">
              <button
                :for={m <- p.oauth}
                phx-click="oauth"
                phx-value-provider={p.id}
                phx-value-method={m.id}
                class="btn btn-sm btn-outline"
              >
                {m.label}
              </button>
              <.form :if={p.key?} for={%{}} as={:key} phx-submit="connect_key" class="flex gap-2">
                <input type="hidden" name="provider" value={p.id} />
                <input
                  name="key"
                  type="password"
                  autocomplete="off"
                  class="input input-bordered input-sm w-64"
                  placeholder="API key"
                />
                <button class="btn btn-sm">Connect key</button>
              </.form>
            </div>
          </div>
        </div>
      </div>

      <div :if={@models != []} class="mt-8">
        <.form for={%{}} as={:model} id="model-form" phx-change="model">
          <label class="text-sm font-semibold">Model for your Peons</label>
          <select name="model" class="select select-bordered w-full mt-1">
            <option :for={m <- Enum.uniq([@model | @models])} value={m} selected={m == @model}>
              {m}
            </option>
          </select>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
