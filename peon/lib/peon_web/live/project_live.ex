defmodule PeonWeb.ProjectLive do
  @moduledoc """
  Chat with the agent on the left (the chat's opencode session), the chat's
  live preview on the right, and the chat's latest changeset with Accept.
  """

  use PeonWeb, :live_view

  alias Peon.{Chat, Chats, Checks, Code, Project, Store}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Chats.subscribe()
      Store.subscribe()
      Checks.subscribe()
    end

    {:ok,
     socket
     |> assign(project: Project.get(), chats: Chats.list(), chat: nil, info: nil)
     |> assign(starting: false, start_error: nil, pending: nil, frame_key: 0)
     |> assign(show_logs: false, logs: "", show_attach: false, step: nil)
     |> assign(changeset: nil, main_id: nil, form: to_form(%{"text" => ""}))}
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

  def handle_event("accept", %{"id" => id}, socket) do
    id = String.to_integer(id)
    main = Code.ref("main")

    case Store.move_ref("main", id, main.version, socket.assigns.user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Changeset #{id} is now on main.") |> load_changeset()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not accept: #{inspect(reason)}")}
    end
  end

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

  def handle_info({:check_step, _id, step, status}, socket),
    do: {:noreply, socket |> assign(step: {step, status}) |> load_changeset()}

  def handle_info(_msg, socket), do: {:noreply, load_changeset(socket)}

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
    assign(socket,
      changeset: Chats.latest_changeset(socket.assigns.chat.id),
      main_id: Code.ref("main").changeset_id
    )
  end

  defp start_error({:session, _}),
    do: "The agent started but could not open a session. Is an AI provider connected in Burrow?"

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

      <div class="flex flex-1 min-h-0">
        <nav class="w-56 shrink-0 border-r border-base-300 bg-base-100 overflow-y-auto hidden md:block">
          <.link patch={~p"/"} class="btn btn-sm btn-primary m-3 w-[calc(100%-1.5rem)]">
            <.icon name="hero-plus" class="size-4" /> New chat
          </.link>
          <ul class="menu menu-sm w-full">
            <li :for={c <- @chats}>
              <.link patch={~p"/c/#{c.id}"} class={[@chat && @chat.id == c.id && "menu-active"]}>
                <span class="truncate">{c.title}</span>
              </.link>
            </li>
          </ul>
        </nav>

        <section class="flex flex-col w-full md:w-[32rem] shrink-0 border-r border-base-300 bg-base-100 min-h-0">
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

          <.changeset_panel :if={@changeset} changeset={@changeset} main_id={@main_id} step={@step} />

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
              The agent is working… <button phx-click="interrupt" class="link">Stop</button>
            </span>
            <button phx-click="toggle_attach" class="link ml-auto">Open in opencode</button>
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
              <button phx-click="reload_preview" class="btn btn-xs btn-ghost ml-auto" title="Reload">
                <.icon name="hero-arrow-path" class="size-4" />
              </button>
              <button phx-click="restart_preview" class="btn btn-xs btn-ghost">Restart</button>
              <button phx-click="toggle_logs" class="btn btn-xs btn-ghost">Logs</button>
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
  attr :main_id, :integer, required: true
  attr :step, :any

  defp changeset_panel(assigns) do
    ~H"""
    <div class="border-t border-base-300 px-4 py-2 text-xs space-y-1 bg-base-200/50">
      <div class="flex items-center gap-2">
        <span class="font-semibold">Changeset #{@changeset.id}</span>
        <span class={["badge badge-xs", cs_badge(@changeset, @main_id)]}>{cs_status(
          @changeset,
          @main_id
        )}</span>
        <button
          :if={@changeset.status == "passed" and @changeset.parent_id == @main_id}
          phx-click="accept"
          phx-value-id={@changeset.id}
          data-confirm="Accept this changeset onto main?"
          class="btn btn-xs btn-success ml-auto"
        >
          Accept to main
        </button>
      </div>
      <div class="opacity-70 truncate">{@changeset.intent}</div>
      <div class="flex gap-2 flex-wrap">
        <span :for={step <- @changeset.checks["steps"] || []} class={step_class(step["status"])}>
          {step["name"]} {(step["duration_ms"] && "#{div(step["duration_ms"], 1000)}s") || ""}
        </span>
        <span :if={@changeset.status == "checking"} class="opacity-60">checking… {step_text(@step)}</span>
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

  defp cs_status(cs, main_id) when cs.id == main_id, do: "on main"
  defp cs_status(cs, _), do: cs.status

  defp cs_badge(cs, main_id) when cs.id == main_id, do: "badge-success"
  defp cs_badge(%{status: "passed"}, _), do: "badge-success badge-outline"
  defp cs_badge(%{status: "failed"}, _), do: "badge-error"
  defp cs_badge(%{status: "superseded"}, _), do: "badge-ghost"
  defp cs_badge(_, _), do: "badge-warning"

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
