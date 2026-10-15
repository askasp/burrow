defmodule PeonWeb.ProjectLive do
  @moduledoc """
  Chat with the agent on the left (the chat's opencode session), the chat's
  live preview on the right, and the chat's latest changeset. The ship bar on
  top shows main's tests, staging and prod, with incidents and deploys below.
  """

  use PeonWeb, :live_view

  alias Peon.{Chat, Chats, Checks, Code, Env, Incidents, Project, Ship, Store, Verifier}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Chats.subscribe()
      Store.subscribe()
      Checks.subscribe()
      Env.subscribe()
      Incidents.subscribe()
    end

    {:ok,
     socket
     |> assign(project: Project.get(), chats: Chats.list(), chat: nil, info: nil)
     |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
     |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
     |> assign(changeset: nil, main_id: nil, form: to_form(%{"text" => ""}))
     |> assign(landed?: false, held: nil, env_names: Env.names(), show_ship: false)
     |> assign(envs: Map.new(Env.names(), &{&1, Env.info(&1)}))
     |> load_ship()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Chats.get(id) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      chat ->
        if old = socket.assigns.chat,
          do: Phoenix.PubSub.unsubscribe(Peon.PubSub, "chat:#{old.id}")

        if connected?(socket), do: Chat.subscribe(id)

        socket =
          socket
          |> assign(chat: chat, info: nil, start_error: nil, show_logs: false)
          |> load_changeset()

        if connected?(socket),
          do:
            {:noreply,
             socket
             |> assign(starting: true)
             |> start_async(:chat, fn -> Chat.ensure_started(id) end)},
          else: {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    if old = socket.assigns.chat, do: Phoenix.PubSub.unsubscribe(Peon.PubSub, "chat:#{old.id}")
    {:noreply, assign(socket, chat: nil, info: nil, changeset: nil, starting: false)}
  end

  @impl true
  def handle_async(:chat, {:ok, {:ok, info}}, socket) do
    socket = assign(socket, info: info, starting: false)

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

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.chat && socket.assigns.info ->
        {:noreply, socket |> assign(form: to_form(%{"text" => ""})) |> prompt(text)}

      socket.assigns.chat ->
        {:noreply, assign(socket, pending: text)}

      true ->
        chat = Chats.create(text, socket.assigns.user)
        {:noreply, socket |> assign(pending: text) |> push_patch(to: ~p"/c/#{chat.id}")}
    end
  end

  def handle_event("interrupt", _params, socket) do
    Chat.interrupt(socket.assigns.chat.id)
    {:noreply, socket}
  end

  def handle_event("land", %{"id" => id}, socket) do
    case Store.land(String.to_integer(id), socket.assigns.user) do
      {:ok, cs} ->
        {:noreply, socket |> info("Changeset #{cs.id} is now on main.") |> load_changeset()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not land: #{inspect(reason)}")}
    end
  end

  def handle_event("revert", %{"id" => id}, socket) do
    case Ship.revert(String.to_integer(id), socket.assigns.user) do
      {:ok, cs} ->
        {:noreply, info(socket, "Revert submitted as ##{cs.id}; it lands once checked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revert: #{inspect(reason)}")}
    end
  end

  def handle_event("promote", %{"id" => id}, socket) do
    prod = Code.ref("prod")
    user = socket.assigns.user
    version = if prod, do: prod.version, else: 0

    case Store.move_ref("prod", String.to_integer(id), version, user, approved_by: user) do
      {:ok, _} ->
        {:noreply, info(socket, "Deploying ##{id} to prod.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not promote: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_auto_promote", _params, socket) do
    on? = Project.settings()["auto_promote"] != true
    Project.put_settings(%{"auto_promote" => on?, "auto_promote_by" => socket.assigns.user})
    {:noreply, load_ship(socket)}
  end

  def handle_event("restart_env", %{"env" => env}, socket) do
    Env.restart(env)
    {:noreply, socket}
  end

  def handle_event("fix_incident", %{"id" => id}, socket) do
    incident = Incidents.fix(Incidents.get(String.to_integer(id)), socket.assigns.user)
    {:noreply, push_patch(socket, to: ~p"/c/#{incident.chat_id}")}
  end

  def handle_event("resolve_incident", %{"id" => id}, socket) do
    Incidents.resolve(Incidents.get(String.to_integer(id)))
    {:noreply, socket}
  end

  def handle_event("toggle_ship", _params, socket),
    do: {:noreply, socket |> update(:show_ship, &(!&1)) |> load_ship()}

  def handle_event("restart_preview", _params, socket) do
    Chat.restart_preview(socket.assigns.chat.id)
    {:noreply, socket}
  end

  def handle_event("reload_preview", _params, socket),
    do: {:noreply, update(socket, :frame_key, &(&1 + 1))}

  def handle_event("toggle_logs", _params, socket) do
    socket = update(socket, :show_logs, &(!&1))

    case socket.assigns.show_logs && Chat.logs(socket.assigns.chat.id) do
      {:ok, logs} -> {:noreply, assign(socket, logs: logs)}
      _ -> {:noreply, socket}
    end
  end

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

  def handle_info({:conflicts, paths}, socket),
    do: {:noreply, update_info(socket, conflicts: paths)}

  def handle_info({:chat_created, _}, socket), do: {:noreply, assign(socket, chats: Chats.list())}

  def handle_info({:env, name, info}, socket) do
    socket = update(socket, :envs, &Map.put(&1, name, info))
    # Stats arrive every few seconds; only reload the lists when something moved.
    if info.deploy || socket.assigns.show_ship,
      do: {:noreply, load_ship(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:incident, _}, socket), do: {:noreply, load_ship(socket)}

  def handle_info({:check_step, _id, step, status}, socket),
    do: {:noreply, socket |> assign(step: {step, status}) |> load_changeset()}

  def handle_info(:clear_info, socket), do: {:noreply, clear_flash(socket, :info)}

  def handle_info(_msg, socket), do: {:noreply, socket |> load_changeset() |> load_ship()}

  # Info flashes clear themselves so they don't cover the ship bar; errors stay.
  defp info(socket, text) do
    Process.send_after(self(), :clear_info, 4_000)
    put_flash(socket, :info, text)
  end

  defp prompt(socket, text) do
    case Chat.send_message(socket.assigns.chat.id, text) do
      :ok -> update_info(socket, busy?: true)
      {:error, reason} -> put_flash(socket, :error, "Could not send: #{inspect(reason)}")
    end
  end

  defp update_info(%{assigns: %{info: nil}} = socket, _changes), do: socket

  defp update_info(socket, changes),
    do: assign(socket, info: Map.merge(socket.assigns.info, Map.new(changes)))

  defp load_changeset(%{assigns: %{chat: nil}} = socket), do: socket

  defp load_changeset(socket) do
    main_id = Code.ref("main").changeset_id
    changeset = Chats.latest_changeset(socket.assigns.chat.id)

    assign(socket,
      changeset: changeset,
      main_id: main_id,
      landed?: changeset != nil and Code.ancestor?(changeset.id, main_id),
      held: if(changeset && changeset.status == "passed", do: Ship.review_reasons(changeset))
    )
  end

  defp load_ship(socket) do
    main =
      case Code.resolve("main") do
        {:ok, cs} -> cs
        _ -> nil
      end

    socket =
      assign(socket,
        main: main,
        incidents: Incidents.list(),
        culprit: Verifier.culprit(),
        auto_promote: Project.settings()["auto_promote"] == true
      )

    if socket.assigns.show_ship,
      do: assign(socket, deploys: Map.new(socket.assigns.env_names, &{&1, Env.deploys(&1, 5)})),
      else: assign(socket, deploys: %{})
  end

  defp start_error({:session, _}),
    do: "The agent started but could not open a session. Is an AI provider connected in Burrow?"

  defp start_error(:no_free_preview_port),
    do:
      "Every preview slot is in use by another chat. Close one, or wait for an idle chat to stop."

  defp start_error(reason), do: "The agent could not start: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-base-200">
      <Layouts.flash_group flash={@flash} />
      <header class="flex items-center gap-3 px-4 h-12 border-b border-base-300 bg-base-100 shrink-0">
        <.link navigate={~p"/"} class="font-semibold">{@project && @project.name}</.link>
        <span class="text-xs opacity-60">Peon</span>
        <div class="ml-auto text-xs opacity-60">{@user}</div>
      </header>

      <.ship_bar
        auto_promote={@auto_promote}
        main={@main}
        culprit={@culprit}
        envs={@envs}
        env_names={@env_names}
        incidents={@incidents}
      />
      <.ship_panel
        :if={@show_ship}
        auto_promote={@auto_promote}
        envs={@envs}
        env_names={@env_names}
        incidents={@incidents}
        deploys={@deploys}
        culprit={@culprit}
      />

      <div class="flex flex-1 min-h-0">
        <nav
          data-kb-zoom-hide
          class="w-56 shrink-0 border-r border-base-300 bg-base-100 overflow-y-auto hidden md:block"
        >
          <.link
            patch={~p"/"}
            data-kb="row"
            data-kb-action="new"
            class="btn btn-sm btn-primary m-3 w-[calc(100%-1.5rem)]"
          >
            <.icon name="hero-plus" class="size-4" /> New chat
          </.link>
          <ul class="menu menu-sm w-full">
            <li :for={c <- @chats}>
              <.link
                patch={~p"/c/#{c.id}"}
                data-kb="item"
                data-kb-current={if(@chat && @chat.id == c.id, do: "1")}
                class={[@chat && @chat.id == c.id && "menu-active"]}
              >
                <span class="truncate">{c.title}</span>
              </.link>
            </li>
          </ul>
        </nav>

        <section
          data-kb-zoom-hide
          class="flex flex-col w-full md:w-[32rem] shrink-0 border-r border-base-300 bg-base-100 min-h-0"
        >
          <div id="messages" class="flex-1 overflow-y-auto p-4 space-y-3" phx-hook=".ScrollBottom">
            <div :if={@chat == nil} class="text-sm opacity-70 space-y-2 pt-8">
              <p class="text-lg font-semibold opacity-100">What should we build?</p>
              <p>
                Describe a feature or a whole app. The agent writes the code in its own workspace, Peon checks every submission, and the preview shows it live.
              </p>
            </div>
            <div :if={@starting} class="text-sm opacity-70 flex items-center gap-2">
              <span class="loading loading-spinner loading-sm"></span> Starting the agent and preview…
            </div>
            <div :if={@start_error} class="alert alert-error text-sm">{@start_error}</div>
            <.message :for={m <- (@info && @info.messages) || []} message={m} />
            <div :if={@pending} class="chat chat-end">
              <div class="chat-bubble chat-bubble-primary text-sm whitespace-pre-wrap opacity-60">
                {@pending}
              </div>
            </div>
          </div>

          <div :if={@info && @info.conflicts != []} class="alert alert-warning rounded-none text-xs">
            Main changed files this chat also changed (the chat's version is kept): {Enum.join(
              @info.conflicts,
              ", "
            )}
          </div>

          <.changeset_panel
            :if={@changeset}
            changeset={@changeset}
            landed?={@landed?}
            held={@held}
            step={@step}
          />

          <.form for={@form} phx-submit="send" class="p-3 border-t border-base-300 flex gap-2">
            <textarea
              name="text"
              rows="2"
              id="chat-input"
              phx-hook=".SubmitOnEnter"
              class="textarea textarea-bordered flex-1 text-sm"
              placeholder={
                if @chat, do: "Ask for a change…", else: "e.g. A booking system for saunas…"
              }
            >{@form[:text].value}</textarea>
            <button class="btn btn-primary self-end"><.icon name="hero-paper-airplane" class="size-4" /></button>
          </.form>
          <div :if={@info} class="px-4 pb-2 text-xs opacity-70 flex items-center gap-3">
            <span :if={@info.busy?} class="flex items-center gap-2">
              <span class="loading loading-dots loading-xs"></span>
              The agent is working…
              <button phx-click="interrupt" data-kb="row" data-kb-action="stop" class="link">
                Stop
              </button>
            </span>
            <button phx-click="toggle_attach" data-kb="row" class="link ml-auto">
              Open in opencode
            </button>
          </div>
          <pre
            :if={@info && @show_attach}
            class="mx-4 mb-3 text-xs bg-base-200 p-2 rounded whitespace-pre-wrap break-all"
          >{@info.attach}</pre>
        </section>

        <section class="flex-1 flex flex-col min-w-0 min-h-0">
          <div class="flex items-center gap-2 px-3 h-10 border-b border-base-300 bg-base-100 text-sm shrink-0">
            <%= if @info do %>
              <span class={["badge badge-sm", status_badge(@info.preview_status)]}>{status_text(
                @info.preview_status
              )}</span>
              <a href={@info.preview_url} target="_blank" class="link link-hover truncate">{@info.preview_url}</a>
              <button
                phx-click="reload_preview"
                data-kb="row"
                data-kb-action="reload"
                class="btn btn-xs btn-ghost ml-auto"
                title="Reload"
              >
                <.icon name="hero-arrow-path" class="size-4" />
              </button>
              <button
                phx-click="restart_preview"
                data-kb="row"
                data-kb-action="restart"
                class="btn btn-xs btn-ghost"
              >
                Restart
              </button>
              <button
                phx-click="toggle_logs"
                data-kb="row"
                data-kb-action="logs"
                class="btn btn-xs btn-ghost"
              >
                Logs
              </button>
            <% else %>
              <span class="opacity-60">No preview yet</span>
            <% end %>
          </div>
          <div class="flex-1 relative min-h-0 bg-base-100">
            <iframe
              :if={@info && @info.preview_status == :running}
              id={"preview-#{@frame_key}"}
              src={@info.preview_url}
              class="absolute inset-0 w-full h-full"
            />
            <div
              :if={@info && @info.preview_status != :running}
              class="absolute inset-0 grid place-items-center text-sm opacity-70"
            >
              {preview_message(@info.preview_status)}
            </div>
            <pre
              :if={@show_logs}
              class="absolute bottom-0 inset-x-0 h-1/2 overflow-auto bg-neutral text-neutral-content text-xs p-3"
            >{@logs}</pre>
          </div>
        </section>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
      export default {
        mounted() { this.el.scrollTop = this.el.scrollHeight },
        updated() { this.el.scrollTop = this.el.scrollHeight }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
      export default {
        mounted() {
          this.el.addEventListener("keydown", e => {
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

  attr :message, :map, required: true

  defp message(%{message: %{role: :user}} = assigns) do
    ~H"""
    <div class="chat chat-end">
      <div class="chat-bubble chat-bubble-primary text-sm whitespace-pre-wrap">{@message.text}</div>
    </div>
    """
  end

  defp message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="text-sm whitespace-pre-wrap">{@message.text}</div>
    """
  end

  # Peon's own answers (submit results) are shown in full; other tools in one
  # line, with their output only when they failed.
  defp message(%{message: %{role: :tool, peon?: true, detail: detail}} = assigns)
       when is_binary(detail) and detail != "" do
    ~H"""
    <div class="text-xs border-l-2 border-primary pl-2 space-y-1">
      <div class="font-mono opacity-60 truncate">→ {@message.text}</div>
      <div class="whitespace-pre-wrap">{@message.detail}</div>
    </div>
    """
  end

  defp message(%{message: %{role: :tool, detail: detail}} = assigns)
       when is_binary(detail) and detail != "" do
    ~H"""
    <details class="text-xs">
      <summary class={["font-mono truncate cursor-pointer", tool_class(@message[:status])]}>
        → {@message.text}
      </summary>
      <pre class="whitespace-pre-wrap opacity-70 pl-3">{@message.detail}</pre>
    </details>
    """
  end

  defp message(%{message: %{role: :tool}} = assigns) do
    ~H"""
    <div class={["text-xs font-mono truncate", tool_class(@message[:status])]}>→ {@message.text}</div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div class="alert alert-error text-xs whitespace-pre-wrap">{@message.text}</div>
    """
  end

  attr :changeset, :map, required: true
  attr :landed?, :boolean, required: true
  attr :held, :list
  attr :step, :any

  defp changeset_panel(assigns) do
    ~H"""
    <div class="border-t border-base-300 px-4 py-2 text-xs space-y-1 bg-base-200/50">
      <div class="flex items-center gap-2">
        <span class="font-semibold">Changeset #{@changeset.id}</span>
        <span class={["badge badge-xs", cs_badge(@changeset, @landed?)]}>{cs_status(
          @changeset,
          @landed?
        )}</span>
        <span :if={@landed?} class={["badge badge-xs", verify_badge(@changeset)]}>
          tests {verify_text(@changeset)}
        </span>
        <button
          :if={@changeset.status == "passed" and not @landed?}
          phx-click="land"
          phx-value-id={@changeset.id}
          data-kb="row"
          data-kb-action="land"
          data-confirm="Land this changeset on main?"
          class="btn btn-xs btn-success ml-auto"
        >
          Land on main
        </button>
      </div>
      <div class="opacity-70 truncate">{@changeset.intent}</div>
      <div :if={@held not in [nil, []] and not @landed?} class="text-warning">
        Needs your review: {Enum.join(@held, "; ")}
      </div>
      <div class="flex gap-2 flex-wrap">
        <span :for={step <- @changeset.checks["steps"] || []} class={step_class(step["status"])}>
          {step["name"]} {(step["duration_ms"] && "#{div(step["duration_ms"], 1000)}s") || ""}
        </span>
        <span :if={@changeset.status == "checking"} class="opacity-60">checking… {step_text(@step)}</span>
      </div>
    </div>
    """
  end

  attr :main, :map
  attr :culprit, :map
  attr :auto_promote, :boolean, required: true
  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :incidents, :list, required: true

  defp ship_bar(assigns) do
    staging = assigns.envs["staging"]
    prod = assigns.envs["prod"]

    assigns =
      assign(assigns,
        promote:
          !assigns.auto_promote && staging && prod && staging.good &&
            staging.good != prod.deployed && staging.good,
        open: Enum.count(assigns.incidents, &(&1.status != "resolved"))
      )

    ~H"""
    <div class="flex items-center gap-4 px-4 h-9 border-b border-base-300 bg-base-100 text-xs shrink-0 overflow-x-auto">
      <span :if={@main} class="flex items-center gap-1 shrink-0">
        <span class="opacity-60">main</span>
        #{@main.id}
        <span class={["badge badge-xs", verify_badge(@main)]}>
          tests {verify_text(@main)}
        </span>
      </span>
      <span :if={@culprit} class="text-error shrink-0" title={@culprit.intent}>
        broken by #{@culprit.id}
        <button phx-click="revert" phx-value-id={@culprit.id} data-kb="row" class="link">
          revert
        </button>
      </span>
      <span :for={name <- @env_names} class="flex items-center gap-1 shrink-0">
        <span class="opacity-60">{name}</span>
        <span
          :if={name == "prod" and @auto_promote}
          class="badge badge-xs badge-outline"
          title="Prod follows every healthy staging deploy"
        >
          auto
        </span>
        <%= if info = @envs[name] do %>
          <a
            :if={info.deployed}
            href={info.url}
            target="_blank"
            data-kb="row"
            class="link link-hover"
          >
            #{info.deployed}
          </a>
          <span class={["badge badge-xs", env_badge(info.status)]}>{env_text(info)}</span>
          <span
            :if={info.stats}
            class="opacity-50 hidden lg:inline"
            title="From the running node (observer): memory, processes, run queue"
          >
            {mb(info.stats["total"])} MB · {info.stats["process_count"]} procs · rq {info.stats[
              "run_queue"
            ]}
          </span>
        <% else %>
          <span class="opacity-60">off</span>
        <% end %>
      </span>
      <button
        :if={@promote}
        phx-click="promote"
        phx-value-id={@promote}
        data-kb="row"
        data-kb-action="promote"
        data-confirm={"Deploy ##{@promote} (healthy on staging) to prod?"}
        class="btn btn-xs btn-primary shrink-0"
      >
        Promote #{@promote} to prod
      </button>
      <button
        phx-click="toggle_ship"
        data-kb="row"
        data-kb-action="ship"
        class="ml-auto link shrink-0"
      >
        <span class={[@open > 0 && "text-error font-semibold"]}>
          {@open} {if(@open == 1, do: "incident", else: "incidents")}
        </span>
        · deploys
      </button>
    </div>
    """
  end

  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :incidents, :list, required: true
  attr :deploys, :map, required: true
  attr :culprit, :map
  attr :auto_promote, :boolean, required: true

  defp ship_panel(assigns) do
    ~H"""
    <div
      id="ship-panel"
      class="grid md:grid-cols-2 gap-4 px-4 py-3 border-b border-base-300 bg-base-100 text-xs max-h-80 overflow-y-auto shrink-0"
    >
      <div class="space-y-2">
        <div class="font-semibold">Incidents</div>
        <div :if={@incidents == []} class="opacity-60">No errors reported.</div>
        <div :for={i <- @incidents} class="flex items-start gap-2">
          <span class="badge badge-xs badge-ghost">{i.env}</span>
          <div class="flex-1 min-w-0">
            <div class={["truncate", i.status != "resolved" && "text-error"]} title={i.detail}>
              {i.title}
            </div>
            <div class="opacity-60">
              {i.count}× · {i.status}
              <.link :if={i.chat_id} patch={~p"/c/#{i.chat_id}"} data-kb="row" class="link">
                chat
              </.link>
            </div>
          </div>
          <button
            :if={i.status == "open"}
            phx-click="fix_incident"
            phx-value-id={i.id}
            data-kb="row"
            class="link"
          >
            Fix with AI
          </button>
          <button
            :if={i.status != "resolved"}
            phx-click="resolve_incident"
            phx-value-id={i.id}
            data-kb="row"
            class="link opacity-60"
          >
            Resolve
          </button>
        </div>
      </div>
      <div class="space-y-3">
        <div :for={name <- @env_names} class="space-y-1">
          <div class="flex items-center gap-2">
            <span class="font-semibold">{name}</span>
            <label :if={name == "prod"} class="flex items-center gap-1 cursor-pointer">
              <input
                id="auto-promote"
                type="checkbox"
                class="toggle toggle-xs"
                data-kb="row"
                checked={@auto_promote}
                phx-click="toggle_auto_promote"
              />
              <span>auto-promote healthy staging</span>
            </label>
            <span :if={stats = @envs[name] && @envs[name].stats} class="opacity-60">
              {stats["process_count"]} processes · {mb(stats["total"])} MB · run queue {stats[
                "run_queue"
              ]}
            </span>
            <span :if={!(@envs[name] && @envs[name].deployed)} class="opacity-60">
              nothing deployed yet
            </span>
            <button
              :if={@envs[name] && @envs[name].deployed}
              phx-click="restart_env"
              phx-value-env={name}
              data-kb="row"
              class="link ml-auto"
            >
              Restart
            </button>
          </div>
          <div :for={d <- @deploys[name] || []} class="flex gap-2">
            <span>#{d.changeset_id}</span>
            <span class="opacity-60">{d.mode}</span>
            <span class={deploy_class(d.status)}>{d.status}</span>
            <span class="opacity-60 truncate" title={d.detail}>{d.detail}</span>
          </div>
          <pre
            :if={@envs[name] && @envs[name].deployed}
            title="A remote IEx shell on the running node"
            class="bg-base-200 p-1 rounded whitespace-pre-wrap break-all opacity-70"
          >{@envs[name].attach}</pre>
        </div>
      </div>
    </div>
    """
  end

  defp step_text({step, status}), do: "#{step} #{status}"
  defp step_text(_), do: ""

  defp tool_class("error"), do: "text-error"
  defp tool_class("completed"), do: "opacity-60"
  defp tool_class(_), do: "opacity-60"

  defp step_class("passed"), do: "text-success"
  defp step_class(_), do: "text-error"

  defp cs_status(_cs, true), do: "on main"
  defp cs_status(cs, false), do: cs.status

  defp cs_badge(_cs, true), do: "badge-success"
  defp cs_badge(%{status: "passed"}, _), do: "badge-success badge-outline"
  defp cs_badge(%{status: "failed"}, _), do: "badge-error"
  defp cs_badge(%{status: "superseded"}, _), do: "badge-ghost"
  defp cs_badge(_, _), do: "badge-warning"

  # The imported template is the baseline: never tested, counted as passing.
  defp verify_text(%{verify: %{"status" => status}}), do: status
  defp verify_text(%{parent_id: nil}), do: "baseline"
  defp verify_text(_), do: "pending"

  defp verify_badge(%{verify: %{"status" => "passed"}}), do: "badge-success"
  defp verify_badge(%{verify: %{"status" => "failed"}}), do: "badge-error"
  defp verify_badge(%{parent_id: nil}), do: "badge-success badge-outline"
  defp verify_badge(_), do: "badge-ghost"

  defp env_text(%{status: :watching, deploy: %{target: id}}), do: "watching ##{id}"
  defp env_text(%{status: :loading, deploy: %{target: id}}), do: "hot-loading ##{id}"
  defp env_text(%{status: :booting, deploy: %{target: id}}), do: "starting ##{id}"
  defp env_text(%{status: {:crashed, _}}), do: "crashed"
  defp env_text(%{status: status}), do: to_string(status)

  defp env_badge(:running), do: "badge-success"

  defp env_badge(status) when status in [:loading, :booting, :watching, :attaching],
    do: "badge-warning"

  defp env_badge(:stopped), do: "badge-ghost"
  defp env_badge(_), do: "badge-error"

  defp deploy_class("healthy"), do: "text-success"
  defp deploy_class("failed"), do: "text-error"
  defp deploy_class(_), do: "text-warning"

  defp mb(nil), do: "?"
  defp mb(bytes), do: div(bytes, 1_048_576)

  defp status_badge(:running), do: "badge-success"
  defp status_badge(:starting), do: "badge-warning"
  defp status_badge(_), do: "badge-error"

  defp status_text({:crashed, _}), do: "stopped"
  defp status_text(status), do: to_string(status)

  defp preview_message(:starting),
    do: "Starting the preview (the first start fetches and compiles dependencies)…"

  defp preview_message({:crashed, code}),
    do: "The preview stopped (exit #{code}). Check the logs or restart it."

  defp preview_message(_), do: ""
end
