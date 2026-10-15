defmodule PeonWeb.ProjectLive do
  @moduledoc """
  The workspace, laid out as the Peon UI kit's "Peon workspace" board (the
  Burrow design): the project and its chats on the left, the chat with its
  current changeset in the middle, and the live preview on the right, which
  switches between the chat's dev preview, staging and prod. Main's tests,
  staging and prod sit under the chats; incidents and deploys open in a panel.
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
     |> assign(project: Project.get(), chat: nil, info: nil, preview_env: "dev")
     |> assign(burrow_url: Application.get_env(:peon, :burrow_url))
     |> load_chats()
     |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
     |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
     |> assign(changeset: nil, main_id: nil, form: to_form(%{"text" => ""}))
     |> assign(landed?: false, held: nil, env_names: Env.names(), show_ship: false)
     # Phones: one pane at a time, chats in a drawer
     |> assign(pane: "chat", drawer: false)
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
          |> assign(chat: chat, info: nil, start_error: nil, show_logs: false, drawer: false)
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

    {:noreply,
     assign(socket, chat: nil, info: nil, changeset: nil, starting: false, drawer: false)}
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

  def handle_event("drawer", _params, socket),
    do: {:noreply, update(socket, :drawer, &(!&1))}

  def handle_event("pane", %{"pane" => pane}, socket) when pane in ["chat", "preview"],
    do: {:noreply, assign(socket, pane: pane)}

  def handle_event("preview_env", %{"env" => env}, socket) when env in ["dev", "staging", "prod"],
    do:
      {:noreply,
       socket |> assign(preview_env: env) |> update(:frame_key, &(&1 + 1)) |> load_logs()}

  def handle_event("toggle_logs", _params, socket),
    do: {:noreply, socket |> update(:show_logs, &(!&1)) |> load_logs()}

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

  def handle_info({:chat_created, _}, socket), do: {:noreply, load_chats(socket)}

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

  # The dev preview's log comes from the chat, staging's and prod's from their env.
  defp load_logs(%{assigns: %{show_logs: false}} = socket), do: socket

  defp load_logs(%{assigns: %{preview_env: "dev", chat: %{id: id}}} = socket) do
    case Chat.logs(id) do
      {:ok, logs} -> assign(socket, logs: logs)
      _ -> socket
    end
  end

  defp load_logs(%{assigns: %{preview_env: env}} = socket) when env in ["staging", "prod"],
    do: assign(socket, logs: Env.logs(env))

  defp load_logs(socket), do: socket

  # The chats with their latest changeset: "#12" open, "✓ #9" on main.
  defp load_chats(socket) do
    main = Code.ref("main")

    chats =
      for chat <- Chats.list() do
        tag =
          case Chats.latest_changeset(chat.id) do
            nil ->
              nil

            cs ->
              if(main && Code.ancestor?(cs.id, main.changeset_id),
                do: "✓ ##{cs.id}",
                else: "##{cs.id}"
              )
          end

        Map.put(chat, :tag, tag)
      end

    assign(socket, chats: chats)
  end

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
    assigns =
      assign(assigns,
        preview: preview(assigns),
        promote: promote_target(assigns),
        open_incidents: Enum.count(assigns.incidents, &(&1.status != "resolved"))
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class={["ws-root", @drawer && "drawer"]} data-pane={@pane}>
      <header class="ws-mbar">
        <button
          type="button"
          phx-click="drawer"
          class="ws-mbar-menu"
          aria-label="Chats and project"
          aria-expanded={to_string(@drawer)}
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
        <span class="ws-mbar-title truncate">{(@chat && @chat.title) || "New chat"}</span>
        <div class="seg" role="group" aria-label="View">
          <button
            :for={{pane, label} <- [{"chat", "Chat"}, {"preview", "Preview"}]}
            type="button"
            phx-click="pane"
            phx-value-pane={pane}
            aria-pressed={to_string(@pane == pane)}
          >
            {label}
          </button>
        </div>
      </header>
      <div :if={@drawer} class="ws-scrim" phx-click="drawer" aria-hidden="true"></div>
      <aside class="ws-left" data-kb-zoom-hide aria-label="Project and chats">
        <div class="ws-left-top">
          <a href={@burrow_url || ~p"/"} class="ws-brand" aria-label="Peon, back to projects">
            <Layouts.mark size={26} /> <span>peon</span>
          </a>
          <div class="ws-project">
            <a :if={@burrow_url} href={@burrow_url} class="ws-back">
              <.icon name="hero-chevron-left" class="size-3.5" /> All projects
            </a>
            <div class="flex items-center gap-2">
              <div class="flex flex-col min-w-0 mr-auto">
                <span class="ws-project-name">{@project && @project.name}</span>
                <span class="mono ws-project-slug">{@project && @project.slug}</span>
              </div>
              <span :if={@info} class={["st", st_tone(@info.preview_status)]}>
                <span class="dot"></span>{preview_word(@info.preview_status)}
              </span>
            </div>
          </div>
          <.link
            patch={~p"/"}
            data-kb="row"
            data-kb-action="new"
            class="btn btn-secondary btn-sm w-full"
          >
            <.icon name="hero-plus" class="size-4" /> New chat
          </.link>
        </div>

        <nav class="ws-convos" aria-label="Chats">
          <div class="eyebrow px-1.5 pt-2 pb-1.5">Chats</div>
          <.link
            :for={c <- @chats}
            patch={~p"/c/#{c.id}"}
            data-kb="item"
            data-kb-current={if(@chat && @chat.id == c.id, do: "1")}
            aria-current={if(@chat && @chat.id == c.id, do: "page")}
            class={["convo", @chat && @chat.id == c.id && "active"]}
          >
            <span class="truncate">{c.title}</span>
            <span :if={c.tag} class="meta mono">{c.tag}</span>
          </.link>
        </nav>

        <.ship_status
          main={@main}
          culprit={@culprit}
          envs={@envs}
          env_names={@env_names}
          auto_promote={@auto_promote}
          promote={@promote}
          open_incidents={@open_incidents}
        />

        <div class="ws-account">
          <span class="ws-avatar" aria-hidden="true">{initials(@user)}</span>
          <span class="truncate">{@user}</span>
        </div>
      </aside>

      <main class="ws-chat" data-kb-zoom-hide>
        <header class="ws-chat-head">
          <h1 class="truncate">{(@chat && @chat.title) || "New chat"}</h1>
          <span :if={@changeset} class="mono muted text-xs shrink-0">
            {if(@landed?, do: "##{@changeset.id} on main", else: "##{@changeset.id}")}
          </span>
        </header>

        <div class="ws-scroll" id="messages" phx-hook=".ScrollBottom">
          <div class="ws-thread">
            <div :if={@chat == nil and @pending == nil} class="ws-hello">
              <Layouts.mark size={56} />
              <h2>Something need doing?</h2>
            </div>
            <div :if={@starting} class="ws-working" role="status">
              <.icon name="hero-arrow-path" class="size-4 spin" /> Starting the agent and preview…
            </div>
            <div :if={@start_error} class="say-error">{@start_error}</div>
            <%= for block <- blocks((@info && @info.messages) || []) do %>
              <.block block={block} />
            <% end %>
            <div :if={@pending} class="bubble-user opacity-60">{@pending}</div>
            <div :if={@info && @info.busy?} class="ws-working" role="status">
              <Layouts.mark size={28} />
              <span class="swing text-[var(--rust)]"><.icon name="hero-wrench" class="size-4" /></span>
              <span class="font-medium">Peon is working…</span>
              <button
                phx-click="interrupt"
                data-kb="row"
                data-kb-action="stop"
                class="btn btn-ghost btn-sm"
              >
                Stop
              </button>
            </div>
          </div>
        </div>

        <div class="ws-bottom">
          <div :if={@culprit} class="notice err">
            <span>Main's tests fail since #{@culprit.id}: {@culprit.intent}</span>
            <button
              phx-click="revert"
              phx-value-id={@culprit.id}
              data-kb="row"
              class="btn btn-danger btn-sm ml-auto"
            >
              revert
            </button>
          </div>
          <div :if={@info && @info.conflicts != []} class="notice warn">
            Main changed files this chat also changed (the chat's version is kept): {Enum.join(
              @info.conflicts,
              ", "
            )}
          </div>
          <.changeset_card
            :if={@changeset}
            changeset={@changeset}
            landed?={@landed?}
            held={@held}
            step={@step}
            envs={@envs}
          />
          <.form for={@form} id="composer" phx-submit="send" class="composer">
            <label class="sr-only" for="chat-input">Message Peon</label>
            <textarea
              name="text"
              rows="2"
              id="chat-input"
              phx-hook=".SubmitOnEnter"
              placeholder={if @chat, do: "Describe a change…", else: "Describe your app…"}
            >{@form[:text].value}</textarea>
            <div class="cbar">
              <button :if={@info} type="button" phx-click="toggle_attach" data-kb="row" class="xlink">
                Open in opencode
              </button>
              <button class="btn btn-primary ws-send" aria-label="Send">
                <.icon name="hero-arrow-up" class="size-4" />
              </button>
            </div>
            <pre :if={@info && @show_attach} class="out mono">{@info.attach}</pre>
          </.form>
        </div>
      </main>

      <section class="ws-prev" aria-label="Live preview">
        <div class="ws-prev-bar">
          <div class="seg" role="group" aria-label="Environment">
            <button
              :for={env <- ["dev" | @env_names]}
              type="button"
              phx-click="preview_env"
              phx-value-env={env}
              aria-pressed={to_string(@preview_env == env)}
            >
              {env}
            </button>
          </div>
          <span :if={@preview.status} class={["st", st_tone(@preview.status)]}>
            <span class="dot"></span>{preview_word(@preview.status)}
          </span>
          <div class="ws-url mono">
            <.icon name="hero-lock-closed" class="size-3.5 shrink-0 muted" />
            <span class="truncate">{@preview.url || "no preview yet"}</span>
          </div>
          <span :if={@preview.ref} class="tag mono" title="Version shown in the preview">{@preview.ref}</span>
          <button
            :if={@preview.url}
            type="button"
            phx-click="reload_preview"
            data-kb="row"
            data-kb-action="reload"
            class="icon-btn"
            aria-label="Reload preview"
          >
            <.icon name="hero-arrow-path" class="size-[18px]" />
          </button>
          <a
            :if={@preview.url}
            href={@preview.url}
            target="_blank"
            rel="noopener"
            data-kb="row"
            class="icon-btn"
            aria-label={"Open #{@preview_env} in a new tab"}
            title={"Open #{@preview_env} in a new tab"}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-[17px]" />
          </a>
          <button
            :if={@preview_env == "dev" and @info}
            type="button"
            phx-click="restart_preview"
            data-kb="row"
            data-kb-action="restart"
            class="btn btn-ghost btn-sm"
          >
            Restart
          </button>
          <button
            :if={@preview.url}
            type="button"
            phx-click="toggle_logs"
            data-kb="row"
            data-kb-action="logs"
            aria-pressed={to_string(@show_logs)}
            class="btn btn-secondary btn-sm"
          >
            <.icon name="hero-command-line" class="size-4" /> Logs
          </button>
        </div>

        <div class="ws-prev-body">
          <iframe
            :if={@preview.live?}
            id={"preview-#{@preview_env}-#{@frame_key}"}
            src={@preview.url}
            class="ws-frame"
          />
          <div :if={!@preview.live?} class="ws-prev-empty" role="status">
            <.icon
              :if={@preview.status in [:starting, :booting, :loading, :watching]}
              name="hero-arrow-path"
              class="size-8 spin text-[var(--accent-text)]"
            />
            <div class="ws-prev-title">{@preview.message}</div>
            <a
              :if={@preview[:open] && @preview.url}
              href={@preview.url}
              target="_blank"
              rel="noopener"
              data-kb="row"
              class="btn btn-primary"
            >
              Open {@preview_env} in a new tab
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </a>
          </div>
          <section :if={@show_logs} class="ws-logs" aria-label="Logs">
            <div class="ws-logs-head">
              <.icon name="hero-command-line" class="size-4 muted" />
              <span class="font-semibold text-[13px]">Logs</span>
              <span class="mono muted text-xs">{@project && @project.slug} · {@preview_env}</span>
              <button
                type="button"
                phx-click="toggle_logs"
                class="icon-btn sm ml-auto"
                aria-label="Hide logs"
              >
                <.icon name="hero-chevron-down" class="size-4" />
              </button>
            </div>
            <pre class="ws-logs-body mono">{@logs}</pre>
          </section>
        </div>
      </section>

      <.ship_panel
        :if={@show_ship}
        auto_promote={@auto_promote}
        envs={@envs}
        env_names={@env_names}
        incidents={@incidents}
        deploys={@deploys}
      />
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

  # What the preview pane shows: the chat's dev preview, or staging or prod.
  defp preview(%{preview_env: "dev", info: nil, chat: chat, starting: starting}) do
    message =
      if chat || starting,
        do: "Starting the preview…",
        else: "The preview starts with your first chat."

    %{url: nil, status: if(chat, do: :starting), ref: nil, live?: false, message: message}
  end

  defp preview(%{preview_env: "dev", info: info, changeset: cs}) do
    %{
      url: info.preview_url,
      status: info.preview_status,
      ref: cs && "##{cs.id}",
      live?: info.preview_status == :running,
      message: preview_message(info.preview_status)
    }
  end

  defp preview(%{preview_env: env, envs: envs}) do
    case envs[env] do
      # Real environments keep frame-ancestors 'self' (clickjacking protection),
      # so they open in their own tab instead of the frame.
      %{deployed: id} = info when id != nil ->
        %{
          url: info.url,
          status: info.status,
          ref: "##{id}",
          live?: false,
          message: env_message(env, info),
          open: true
        }

      info ->
        %{
          url: info && info.url,
          status: info && info.status,
          ref: nil,
          live?: false,
          message: "Nothing is deployed to #{env} yet."
        }
    end
  end

  defp promote_target(%{auto_promote: true}), do: nil

  defp promote_target(%{envs: envs}) do
    with %{good: good} when good != nil <- envs["staging"],
         %{} = prod <- envs["prod"],
         true <- good != prod.deployed do
      good
    else
      _ -> nil
    end
  end

  # Consecutive agent output is one Peon turn under the user's message.
  defp blocks(messages) do
    messages
    |> Enum.chunk_by(&(&1.role == :user))
    |> Enum.flat_map(fn
      [%{role: :user} | _] = users -> Enum.map(users, &{:user, &1})
      agent -> [{:peon, drop_preambles(agent)}]
    end)
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

  attr :block, :any, required: true

  defp block(%{block: {:user, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <div class="bubble-user">{@message.text}</div>
    """
  end

  defp block(%{block: {:peon, messages}} = assigns) do
    assigns = assign(assigns, :messages, messages)

    ~H"""
    <div class="say-peon-turn">
      <Layouts.mark size={28} />
      <div class="flex-1 min-w-0 flex flex-col gap-2">
        <div class="text-[13px] font-semibold leading-[18px]">Peon</div>
        <.message :for={m <- @messages} message={m} />
      </div>
    </div>
    """
  end

  attr :message, :map, required: true

  defp message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="say-agent">{@message.text}</div>
    """
  end

  defp message(%{message: %{role: :tool, detail: detail}} = assigns)
       when is_binary(detail) and detail != "" do
    assigns = assign(assigns, tool: split_tool(assigns.message.text))

    ~H"""
    <details class="result" open={@message[:peon?]}>
      <summary class="result-btn">
        <.icon name="hero-chevron-right" class="size-3.5 chev" />
        <span class="mono font-medium text-[var(--text-2)]">{elem(@tool, 0)}</span>
        <span class={["truncate", @message[:status] == "error" && "text-[var(--err)]"]}>{elem(
          @tool,
          1
        )}</span>
      </summary>
      <pre class={["out mono", @message[:peon?] && "peon"]}>{@message.detail}</pre>
    </details>
    """
  end

  defp message(%{message: %{role: :tool}} = assigns) do
    assigns = assign(assigns, tool: split_tool(assigns.message.text))

    ~H"""
    <div class={["tool mono", @message[:status] == "error" && "err"]}>
      <span class="ar">→</span> <span class="nm">{elem(@tool, 0)}</span> {elem(@tool, 1)}
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div class="say-error">{@message.text}</div>
    """
  end

  defp split_tool(text) do
    case String.split(text, " ", parts: 2) do
      [name, rest] -> {name, rest}
      [name] -> {name, ""}
    end
  end

  attr :changeset, :map, required: true
  attr :landed?, :boolean, required: true
  attr :held, :list
  attr :step, :any
  attr :envs, :map, required: true

  defp changeset_card(assigns) do
    verify = assigns.changeset.verify

    steps =
      (assigns.changeset.checks["steps"] || []) ++
        if(assigns.landed? and verify,
          do: [Map.put(verify, "name", "test") |> Map.put_new("duration_ms", nil)],
          else: []
        )

    assigns =
      assign(assigns, steps: steps, flow: flow(assigns.changeset, assigns.landed?, assigns.envs))

    ~H"""
    <section class="framed ws-cs" aria-label="Current changeset">
      <div class="flex items-center gap-2.5 flex-wrap min-h-9">
        <span class="text-[var(--rust)] flex"><.icon
          name="hero-arrows-right-left"
          class="size-[18px]"
        /></span>
        <h2 class="m-0 text-[15px] leading-[22px] font-semibold">Changeset #{@changeset.id}</h2>
        <span class={["st", cs_tone(@changeset, @landed?)]}>
          <span :if={@changeset.status in ["checking", "proposed"]} class="dot"></span>{cs_status(
            @changeset,
            @landed?
          )}
        </span>
        <span :if={@landed?} class={["st", verify_tone(@changeset)]}>tests {verify_text(@changeset)}</span>
      </div>
      <div class="truncate muted text-[13px]">{@changeset.intent}</div>
      <div :if={@steps != [] or @changeset.status == "checking"} class="ws-steps">
        <div :for={step <- @steps} class={["step", step_kind(step["status"])]}>
          <span class="i"><.step_icon status={step["status"]} /></span>
          <span class="mono">{step["name"]}</span>
          <span class="t mono">{seconds(step["duration_ms"])}</span>
        </div>
        <div :if={@changeset.status == "checking"} class="step run">
          <span class="i"><.step_icon status="running" /></span>
          <span class="mono">{step_text(@step)}</span>
        </div>
      </div>
      <div :if={@held not in [nil, []] and not @landed?} class="text-[13px] text-[var(--warn)]">
        Needs your review: {Enum.join(@held, "; ")}
      </div>
      <div class="mrg">
        <div class="flow mono">
          <span class={@flow.dev}>dev #{@changeset.id}</span>
          <.icon name="hero-arrow-right" class="size-3.5" />
          <span class={@flow.main}>main</span>
          <.icon name="hero-arrow-right" class="size-3.5" />
          <span class={@flow.staging}>staging</span>
          <.icon name="hero-arrow-right" class="size-3.5" />
          <span class={@flow.prod}>prod</span>
        </div>
        <button
          :if={@changeset.status == "passed" and not @landed?}
          phx-click="land"
          phx-value-id={@changeset.id}
          data-kb="row"
          data-kb-action="land"
          data-confirm="Land this changeset on main?"
          class="btn btn-primary ml-auto"
        >
          <.icon name="hero-arrows-right-left" class="size-4" /> Land on main
        </button>
      </div>
    </section>
    """
  end

  # Which stages a changeset has reached: landed, and live on staging and prod.
  defp flow(cs, landed?, envs) do
    live? = fn env ->
      landed? and match?(%{deployed: id} when id != nil, envs[env]) and
        Code.ancestor?(cs.id, envs[env].deployed)
    end

    %{
      dev: "on",
      main: landed? && "on",
      staging: live?.("staging") && "on",
      prod: live?.("prod") && "on"
    }
  end

  attr :status, :string, required: true

  defp step_icon(%{status: "passed"} = assigns),
    do: ~H|<.icon name="hero-check" class="size-[15px]" />|

  defp step_icon(%{status: "failed"} = assigns),
    do: ~H|<.icon name="hero-x-mark" class="size-[15px]" />|

  defp step_icon(%{status: "running"} = assigns),
    do: ~H|<.icon name="hero-arrow-path" class="size-[15px] spin" />|

  defp step_icon(assigns), do: ~H|<.icon name="hero-minus-small" class="size-[15px]" />|

  defp step_kind("passed"), do: "pass"
  defp step_kind("failed"), do: "fail"
  defp step_kind(_), do: "wait"

  attr :main, :map
  attr :culprit, :map
  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :auto_promote, :boolean, required: true
  attr :promote, :any
  attr :open_incidents, :integer, required: true

  # Under the chats: main's tests, staging and prod, and the way to incidents.
  defp ship_status(assigns) do
    ~H"""
    <div class="ws-ship" id="ship-status">
      <div class="eyebrow px-1.5 pb-1.5">Ship</div>
      <div :if={@main} class="ws-ship-row">
        <span class="mono">main #{@main.id}</span>
        <span class={["st", verify_tone(@main)]}>tests {verify_text(@main)}</span>
      </div>
      <div :if={@culprit} class="ws-ship-row text-[var(--err)]" title={@culprit.intent}>
        <span>broken by #{@culprit.id}</span>
      </div>
      <div :for={name <- @env_names} class="ws-ship-row">
        <span class="mono">
          {name}<span :if={info = @envs[name]}>{if(info.deployed, do: " ##{info.deployed}")}</span>
          <span
            :if={name == "prod" and @auto_promote}
            class="tag ml-1"
            title="Prod follows every healthy staging deploy"
          >auto</span>
        </span>
        <%= if info = @envs[name] do %>
          <span class={["st", st_tone(info.status)]}><span class="dot"></span>{env_text(info)}</span>
        <% else %>
          <span class="st idle">off</span>
        <% end %>
      </div>
      <button
        :if={@promote}
        phx-click="promote"
        phx-value-id={@promote}
        data-kb="row"
        data-kb-action="promote"
        data-confirm={"Deploy ##{@promote} (healthy on staging) to prod?"}
        class="btn btn-primary btn-sm w-full mt-1"
      >
        Promote #{@promote} to prod
      </button>
      <button
        phx-click="toggle_ship"
        data-kb="row"
        data-kb-action="ship"
        class={["xlink mt-1", @open_incidents > 0 && "text-[var(--err)]"]}
      >
        {@open_incidents} {if(@open_incidents == 1, do: "incident", else: "incidents")} · deploys
      </button>
    </div>
    """
  end

  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :incidents, :list, required: true
  attr :deploys, :map, required: true
  attr :auto_promote, :boolean, required: true

  defp ship_panel(assigns) do
    ~H"""
    <section id="ship-panel" class="ws-panel" aria-label="Incidents and deploys">
      <div class="sec-h">
        <h2 class="m-0 text-[15px] font-semibold">Incidents and deploys</h2>
        <button type="button" phx-click="toggle_ship" class="icon-btn sm" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
      <div class="eyebrow pt-2 pb-1">Incidents</div>
      <ul class="rows">
        <li :if={@incidents == []} class="muted">No errors reported.</li>
        <li :for={i <- @incidents} class="items-start!">
          <span class="tag shrink-0">{i.env}</span>
          <div class="flex-1 min-w-0">
            <div class={["truncate", i.status != "resolved" && "text-[var(--err)]"]} title={i.detail}>
              {i.title}
            </div>
            <div class="meta">
              {i.count}× · {i.status}
              <.link :if={i.chat_id} patch={~p"/c/#{i.chat_id}"} data-kb="row" class="xlink">chat</.link>
            </div>
          </div>
          <button
            :if={i.status == "open"}
            phx-click="fix_incident"
            phx-value-id={i.id}
            data-kb="row"
            class="btn btn-secondary btn-sm"
          >
            Fix with AI
          </button>
          <button
            :if={i.status != "resolved"}
            phx-click="resolve_incident"
            phx-value-id={i.id}
            data-kb="row"
            class="btn btn-ghost btn-sm"
          >
            Resolve
          </button>
        </li>
      </ul>
      <div :for={name <- @env_names} class="pt-5">
        <div class="sec-h">
          <span class="flex items-center gap-3">
            <span class="eyebrow">{name}</span>
            <span :if={stats = @envs[name] && @envs[name].stats} class="meta mono">
              {stats["process_count"]} procs · {mb(stats["total"])} MB · rq {stats["run_queue"]}
            </span>
          </span>
          <label :if={name == "prod"} class="check">
            <input
              id="auto-promote"
              type="checkbox"
              data-kb="row"
              checked={@auto_promote}
              phx-click="toggle_auto_promote"
            /> auto-promote healthy staging
          </label>
          <span :if={!(@envs[name] && @envs[name].deployed)} class="meta">nothing deployed yet</span>
          <button
            :if={@envs[name] && @envs[name].deployed}
            phx-click="restart_env"
            phx-value-env={name}
            data-kb="row"
            class="btn btn-ghost btn-sm"
          >
            Restart
          </button>
        </div>
        <ul class="rows">
          <li :for={d <- @deploys[name] || []}>
            <span class="mono">#{d.changeset_id}</span>
            <span class="meta">{d.mode}</span>
            <span class={["st", deploy_tone(d.status)]}><span class="dot"></span>{d.status}</span>
            <span class="meta truncate" title={d.detail}>{d.detail}</span>
          </li>
        </ul>
        <pre
          :if={@envs[name] && @envs[name].deployed}
          title="A remote IEx shell on the running node"
          class="out mono mt-2"
        >{@envs[name].attach}</pre>
      </div>
    </section>
    """
  end

  defp initials(nil), do: "?"

  defp initials(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp seconds(nil), do: ""
  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp step_text({step, status}), do: "#{step} #{status}"
  defp step_text(_), do: "checking…"

  defp cs_status(_cs, true), do: "on main"
  defp cs_status(%{status: "passed"}, false), do: "passed"
  defp cs_status(cs, false), do: cs.status

  defp cs_tone(_cs, true), do: "ok"
  defp cs_tone(%{status: "passed"}, _), do: "ok"
  defp cs_tone(%{status: "failed"}, _), do: "err"
  defp cs_tone(%{status: "superseded"}, _), do: "idle"
  defp cs_tone(_, _), do: "warn"

  # The imported template is the baseline: never tested, counted as passing.
  defp verify_text(%{verify: %{"status" => status}}), do: status
  defp verify_text(%{parent_id: nil}), do: "baseline"
  defp verify_text(_), do: "pending"

  defp verify_tone(%{verify: %{"status" => "passed"}}), do: "ok"
  defp verify_tone(%{verify: %{"status" => "failed"}}), do: "err"
  defp verify_tone(%{parent_id: nil}), do: "ok"
  defp verify_tone(_), do: "warn"

  defp env_text(%{status: :watching, deploy: %{target: id}}), do: "watching ##{id}"
  defp env_text(%{status: :loading, deploy: %{target: id}}), do: "hot-loading ##{id}"
  defp env_text(%{status: :booting, deploy: %{target: id}}), do: "starting ##{id}"
  defp env_text(%{status: {:crashed, _}}), do: "crashed"
  defp env_text(%{status: status}), do: to_string(status)

  defp st_tone(:running), do: "ok"

  defp st_tone(status) when status in [:starting, :loading, :booting, :watching, :attaching],
    do: "warn"

  defp st_tone(status) when status in [nil, :stopped], do: "idle"
  defp st_tone(_), do: "err"

  defp preview_word({:crashed, _}), do: "stopped"
  defp preview_word(status), do: to_string(status)

  defp deploy_tone("healthy"), do: "ok"
  defp deploy_tone("failed"), do: "err"
  defp deploy_tone(_), do: "warn"

  defp mb(nil), do: "?"
  defp mb(bytes), do: div(bytes, 1_048_576)

  defp preview_message(:starting),
    do: "Starting the preview (the first start fetches and compiles dependencies)…"

  defp preview_message({:crashed, code}),
    do: "The preview stopped (exit #{code}). Check the logs or restart it."

  defp preview_message(_), do: ""

  defp env_message(env, %{status: {:crashed, _}}),
    do: "#{String.capitalize(env)} stopped. Check its logs."

  defp env_message(env, %{status: :running, deployed: id}),
    do:
      "#{String.capitalize(env)} runs ##{id} with its real security headers, so it opens in its own tab."

  defp env_message(env, info), do: "#{String.capitalize(env)}: #{env_text(info)}"
end
