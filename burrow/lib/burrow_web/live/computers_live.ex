defmodule BurrowWeb.ComputersLive do
  @moduledoc """
  Computers: Burrow Bridge's downloads and the user's paired computers
  (`Burrow.Computers`), each online or not, with the folders it shares.
  Adding a folder opens the folder picker on the computer itself, so only
  the person there can widen what Peon reaches; Burrow may only stop
  sharing one. `/computers/approve?code=` is where a bridge sends someone
  to approve its pairing code.
  """

  use BurrowWeb, :live_view

  alias Burrow.{Bridge, Computers}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    if connected?(socket), do: Computers.subscribe(user.id)

    {:ok,
     socket
     |> assign(page_title: "Computers", server: Bridge.server())
     |> assign(picking: MapSet.new(), renaming: nil, pending: nil, code: nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :approve}} = socket) do
    code = params["code"] || ""
    {:noreply, assign(socket, code: code, pending: Computers.pending(code))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, pending: nil)}

  defp load(socket) do
    computers = Computers.list(socket.assigns.current_scope.user.id)
    assign(socket, computers: computers, online: MapSet.new(computers, & &1.id) |> online())
  end

  defp online(ids), do: MapSet.filter(ids, &Computers.online?/1)

  @impl true
  def handle_event("approve", _params, socket) do
    case Computers.approve(socket.assigns.current_scope.user, socket.assigns.code) do
      {:ok, computer} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{computer.name} is paired. Keep burrow-bridge running there.")
         |> push_patch(to: ~p"/computers")}

      {:error, :expired} ->
        {:noreply, assign(socket, pending: nil)}
    end
  end

  def handle_event("refuse", _params, socket) do
    Computers.refuse(socket.assigns.code)
    {:noreply, socket |> put_flash(:info, "Not paired.") |> push_patch(to: ~p"/computers")}
  end

  def handle_event("pick", %{"computer" => id, "mode" => mode}, socket) do
    with %{} = computer <- get(socket, id) do
      {:noreply,
       socket
       |> update(:picking, &MapSet.put(&1, computer.id))
       |> start_async({:pick, computer.id}, fn ->
         Computers.pick_folder(computer.id, mode == "write")
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("forget", %{"id" => id, "path" => path}, socket) do
    with %{} = computer <- get(socket, id),
         {:error, reason} <- Computers.forget_folder(computer.id, path) do
      {:noreply, put_flash(socket, :error, "Couldn't stop sharing #{path}: #{reason(reason)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("rename", %{"id" => id}, socket),
    do: {:noreply, assign(socket, renaming: String.to_integer(id))}

  def handle_event("save_name", %{"computer" => id, "name" => name}, socket) do
    with %{} = computer <- get(socket, id), {:ok, _} <- Computers.rename(computer, name) do
      {:noreply, socket |> assign(renaming: nil) |> load()}
    else
      _ -> {:noreply, assign(socket, renaming: nil)}
    end
  end

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, renaming: nil)}

  def handle_event("remove", %{"id" => id}, socket) do
    if computer = get(socket, id), do: Computers.remove(computer)
    {:noreply, load(socket)}
  end

  defp get(socket, id), do: Computers.get(socket.assigns.current_scope.user.id, id)

  @impl true
  def handle_async({:pick, id}, result, socket) do
    socket = update(socket, :picking, &MapSet.delete(&1, id))

    case result do
      {:ok, {:ok, %{"folder" => %{"path" => path}}}} ->
        {:noreply, socket |> put_flash(:info, "Peon may now use #{path}.") |> load()}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, reason(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "The folder picker failed.")}
    end
  end

  defp reason(:offline), do: "the computer is offline."
  defp reason(:timeout), do: "the computer didn't answer in time."
  defp reason(message) when is_binary(message), do: message

  @impl true
  def handle_info({:computer, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:computer_removed, _id}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(%{live_action: :approve} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:computers}>
      <section :if={@pending} id="approve" class="flex flex-col gap-5 max-w-[480px]">
        <div class="flex flex-col gap-1">
          <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">
            Approve this computer?
          </h1>
          <p class="m-0 text-[15px] text-[var(--text-2)]">
            Peon will be able to work on files there, in folders you share from that computer.
          </p>
        </div>
        <ul class="rows">
          <li>
            <span class="flex-1 text-[var(--text-2)]">Computer</span>
            <span class="font-medium">{@pending.name}</span>
          </li>
          <li>
            <span class="flex-1 text-[var(--text-2)]">System</span>
            <span>{Computers.os_name(@pending.os)} · {@pending.arch}</span>
          </li>
          <li>
            <span class="flex-1 text-[var(--text-2)]">Code</span>
            <span id="approve-code" class="mono text-[18px] font-semibold tracking-[0.08em]">
              {@pending.user_code}
            </span>
          </li>
        </ul>
        <p class="m-0 text-[14px] text-[var(--text-2)]">
          Approve only if the computer's terminal shows the same code.
        </p>
        <div class="flex gap-2">
          <button id="approve-btn" type="button" class="btn btn-primary" phx-click="approve">
            Approve
          </button>
          <button id="refuse-btn" type="button" class="btn btn-ghost" phx-click="refuse">
            Not mine
          </button>
        </div>
      </section>

      <section :if={!@pending} id="approve-gone" class="flex flex-col gap-3 max-w-[480px]">
        <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">
          This code isn't waiting
        </h1>
        <p class="m-0 text-[15px] text-[var(--text-2)]">
          It expired, was used already, or never existed. Run
          <code class="mono">burrow-bridge login</code>
          on the computer for a new one.
        </p>
        <.link navigate={~p"/computers"} class="btn btn-ghost self-start">Computers</.link>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:computers}>
      <div class="flex flex-col gap-1">
        <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">Computers</h1>
        <p class="m-0 text-[15px] text-[var(--text-2)] max-w-[640px]">
          Let Peon work on files on your own computer, in folders you pick there. Optional:
          the rest of Burrow works without it.
        </p>
      </div>

      <section id="setup" class="flex flex-col gap-2 max-w-[720px]">
        <div class="sec-h"><span class="eyebrow">Set up a computer</span></div>
        <ol class="m-0 pl-5 flex flex-col gap-4 text-[14.5px]">
          <li>
            <div class="font-medium">Install Burrow Bridge</div>
            <div class="mt-1.5 text-[var(--text-2)]">Mac or Linux, in a terminal:</div>
            <pre
              id="install-cmd"
              class="mono text-[13px] mt-1 p-3 rounded-lg border border-[var(--border)] select-all whitespace-pre-wrap break-all"
            >curl -fsSL {@server}/bridge/install.sh | sh</pre>
            <div class="mt-2 text-[var(--text-2)]">
              Windows:
              <a id="download-windows" href={~p"/bridge/download/windows-amd64"} download>
                download burrow-bridge.exe
              </a>
              (<a href={~p"/bridge/download/windows-arm64"} download>ARM</a>), then open it. If
              Windows warns, choose More info, then Run anyway.
            </div>
            <div class="mt-2 text-[13px] text-[var(--text-3)] flex flex-wrap gap-x-3 gap-y-1">
              <span>Every download:</span>
              <a
                :for={{target, os, label} <- Computers.targets()}
                href={~p"/bridge/download/#{target}"}
                download
              >
                {os} ({label})
              </a>
            </div>
          </li>
          <li>
            <div class="font-medium">Run <code class="mono">burrow-bridge</code></div>
            <div class="mt-1 text-[var(--text-2)]">
              It opens Burrow to approve the computer, then stays connected while it runs.
            </div>
          </li>
          <li>
            <div class="font-medium">Share a folder</div>
            <div class="mt-1 text-[var(--text-2)]">
              With Add folder… below, or in the terminal:
              <code class="mono">burrow-bridge allow ~/Documents</code>
              (add <code class="mono">--write</code>
              to let Peon change files there).
            </div>
          </li>
        </ol>
      </section>

      <section id="computers" class="flex flex-col max-w-[720px]">
        <div class="sec-h"><span class="eyebrow">Your computers</span></div>
        <p :if={@computers == []} class="m-0 text-[14px] text-[var(--text-3)]">
          No computers yet.
        </p>
        <ul :if={@computers != []} class="rows">
          <li
            :for={c <- @computers}
            id={"computer-#{c.id}"}
            class="!flex-col !items-stretch gap-2 py-3"
          >
            <div class="flex items-center gap-3 flex-wrap">
              <form
                :if={@renaming == c.id}
                phx-submit="save_name"
                class="flex items-center gap-2 flex-1 min-w-0"
              >
                <input type="hidden" name="computer" value={c.id} />
                <input
                  name="name"
                  value={c.name}
                  class="input flex-1 min-w-0"
                  aria-label="Name"
                  phx-mounted={JS.focus()}
                />
                <button class="btn btn-primary btn-sm">Save</button>
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_rename">
                  Cancel
                </button>
              </form>
              <span :if={@renaming != c.id} class="font-medium truncate">{c.name}</span>
              <span :if={@renaming != c.id} class="tag">{Computers.os_name(c.os)}</span>
              <span :if={MapSet.member?(@online, c.id)} class="st ok">
                <span class="dot"></span>Online
              </span>
              <span :if={!MapSet.member?(@online, c.id)} class="st idle">
                <span class="dot"></span>Offline{seen(c)}
              </span>
              <span class="flex-1"></span>
              <button
                :if={@renaming != c.id}
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="rename"
                phx-value-id={c.id}
              >
                Rename
              </button>
              <button
                id={"remove-computer-#{c.id}"}
                type="button"
                class="icon-btn sm"
                aria-label={"Remove #{c.name}"}
                phx-click="remove"
                phx-value-id={c.id}
                data-confirm={"Remove #{c.name}? Peon can't reach it any more, and its Burrow Bridge stops."}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>

            <ul class="m-0 p-0 list-none flex flex-col gap-1">
              <li
                :for={f <- c.folders}
                class="flex items-center gap-2 text-[13.5px] min-h-[28px]"
              >
                <.icon name="hero-folder" class="size-4 text-[var(--text-3)] shrink-0" />
                <span class="mono truncate min-w-0">{f["path"]}</span>
                <span class="tag">{if f["write"], do: "read and change", else: "read"}</span>
                <span class="flex-1"></span>
                <button
                  :if={MapSet.member?(@online, c.id)}
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="forget"
                  phx-value-id={c.id}
                  phx-value-path={f["path"]}
                >
                  Stop sharing
                </button>
              </li>
              <li :if={c.folders == []} class="text-[13.5px] text-[var(--text-3)]">
                Shares no folders yet.
              </li>
            </ul>

            <form
              :if={MapSet.member?(@online, c.id) and c.can_pick}
              id={"pick-#{c.id}"}
              phx-submit="pick"
              class="flex items-center gap-2"
            >
              <input type="hidden" name="computer" value={c.id} />
              <select name="mode" class="select select-sm w-auto" aria-label="What Peon may do">
                <option value="read">Read</option>
                <option value="write">Read and change</option>
              </select>
              <button
                class="btn btn-secondary btn-sm"
                disabled={MapSet.member?(@picking, c.id)}
              >
                {if MapSet.member?(@picking, c.id),
                  do: "Pick the folder on #{c.name}…",
                  else: "Add folder…"}
              </button>
            </form>
            <p
              :if={MapSet.member?(@online, c.id) and !c.can_pick}
              class="m-0 text-[13px] text-[var(--text-3)]"
            >
              This computer has no folder picker: add folders there with <code class="mono">burrow-bridge allow FOLDER</code>.
            </p>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp seen(%{last_seen_at: nil}), do: ""

  defp seen(%{last_seen_at: at}) do
    minutes = div(DateTime.diff(DateTime.utc_now(), at), 60)

    cond do
      minutes < 1 -> " · seen just now"
      minutes < 60 -> " · seen #{minutes} min ago"
      minutes < 48 * 60 -> " · seen #{div(minutes, 60)} h ago"
      true -> " · seen #{Calendar.strftime(at, "%Y-%m-%d")}"
    end
  end
end
