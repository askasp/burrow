defmodule BurrowWeb.ChatsLive do
  @moduledoc """
  The Chats space, laid out as the Peon UI kit's "4f · Chats" board: general
  chats outside projects (`Burrow.GeneralChats`), to ask, search and think.
  The drawer has the switcher on top (Chats, then the projects), a search
  over chats, New chat and the history by day; there is no limit on open
  chats, since nothing gets built here. The chat reads at reading width,
  with no change card, environments or preview. Peon searches the web and
  cites its sources, which the pane on the right lists.

  A conversation goes on in a project from here, never back: "Send to a
  project…" opens a new chat there that starts from it, and "Start a
  project from this" creates a project whose first chat does. Either way
  this chat stays.
  """

  use BurrowWeb, :live_view

  import BurrowWeb.WorkspaceLive.Components,
    only: [model_pick: 1, place_switch: 1, account_menu: 1, rail: 1]

  import BurrowWeb.Markdown, only: [markdown: 1]

  alias Burrow.{Activity, Chats, GeneralChat, GeneralChats, Projects}
  alias Burrow.GeneralChats.Sources

  @accept ~w(.png .jpg .jpeg .gif .webp .pdf .txt .md .csv .json)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      GeneralChats.subscribe(user.id)
      Activity.subscribe()
    end

    socket =
      socket
      |> assign(page_title: "Chats", user_id: user.id, theme: user.theme)
      |> assign(chat: nil, info: nil, messages: [], pages: %{})
      |> assign(sending: false, start_error: nil, pending: nil)
      # The search over chats and where it looks: "chats", "project" (the
      # last project opened) or "everywhere"
      |> assign(q: "", scope: "chats", found: [])
      # The citation picked ({turn, n}) and whether the sources pane shows
      |> assign(cited: nil, show_sources: true)
      # "Send to a project…" and "Start a project from this"
      |> assign(dialog: nil, target: nil, pname: "", dialog_error: nil, notice: nil)
      |> assign(
        busy: if(connected?(socket), do: GeneralChat.busy_ids(user.id), else: MapSet.new())
      )
      |> assign(models: %{}, default_model: Burrow.OpenCode.model(user.id))
      |> assign(form: to_form(%{"text" => ""}))
      |> allow_upload(:files, accept: @accept, max_entries: 4, max_file_size: 10_000_000)
      |> load_chats()
      |> load_rail()

    socket =
      if connected?(socket),
        do: start_async(socket, :models, fn -> Burrow.OpenCode.models(user.id) end),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case GeneralChats.get(socket.assigns.user_id, id) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/chats")}

      chat ->
        if old = socket.assigns.chat, do: GeneralChats.unsubscribe_chat(old.id)
        if connected?(socket), do: GeneralChats.subscribe_chat(chat.id)

        info =
          case connected?(socket) && GeneralChat.info(chat.id) do
            {:ok, info} -> info
            _ -> nil
          end

        {:noreply,
         socket
         |> assign(chat: chat, info: info, pending: nil, start_error: nil, sending: false)
         |> assign(messages: (info && info.messages) || GeneralChats.messages(chat))
         |> assign(pages: GeneralChats.pages(chat), cited: nil, dialog: nil)
         |> assign(page_title: title(chat))}
    end
  end

  # Chats opens on an empty chat: the one there is, else a new one.
  def handle_params(_params, _uri, socket) do
    %{chats: chats, user_id: user_id} = socket.assigns

    chat =
      Enum.find(chats, &(&1.started_at == nil)) ||
        GeneralChats.create_empty(user_id, model_opts(socket.assigns.chat))

    {:noreply, push_patch(socket, to: ~p"/chats/#{chat.id}", replace: true)}
  end

  @impl true
  def handle_async(:models, {:ok, {:ok, models}}, socket) do
    default = Burrow.OpenCode.usable(socket.assigns.default_model, Enum.map(models, &elem(&1, 0)))
    {:noreply, assign(socket, models: Map.new(models), default_model: default)}
  end

  def handle_async(:models, _result, socket), do: {:noreply, socket}

  def handle_async(:send, {:ok, :ok}, socket) do
    info =
      case GeneralChat.info(socket.assigns.chat.id) do
        {:ok, info} -> info
        _ -> socket.assigns.info
      end

    {:noreply, assign(socket, sending: false, info: info)}
  end

  def handle_async(:send, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, sending: false, pending: nil, start_error: send_error(reason))}

  def handle_async(:send, {:exit, reason}, socket),
    do: {:noreply, assign(socket, sending: false, pending: nil, start_error: send_error(reason))}

  @impl true
  def handle_event("send", params, socket) do
    text = String.trim(params["text"] || "")
    %{chat: chat, sending: sending} = socket.assigns

    cond do
      chat == nil or sending ->
        {:noreply, socket}

      text == "" and socket.assigns.uploads.files.entries == [] ->
        {:noreply, socket}

      true ->
        files = take_files(socket, chat)
        text = if text == "", do: look_text(files), else: text

        {:noreply,
         socket
         |> assign(form: to_form(%{"text" => ""}), pending: text, sending: true, start_error: nil)
         |> push_event("composer:put", %{text: ""})
         |> start_async(:send, fn -> GeneralChat.send_message(chat, text, files) end)}
    end
  end

  def handle_event("typing", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_file", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("interrupt", _params, socket) do
    GeneralChat.interrupt(socket.assigns.chat.id)
    {:noreply, socket}
  end

  def handle_event("pick_model", params, socket) do
    %{chat: chat, models: models, default_model: default} = socket.assigns
    model = Map.get(params, "model", chat.model)
    effort = Map.get(params, "effort", chat.effort)
    effort = if effort in Map.get(models, model || default, []), do: effort
    GeneralChats.pick_model(chat, model, effort)
    {:noreply, assign(socket, chat: GeneralChats.get(chat.id))}
  end

  def handle_event("toggle_web", _params, socket) do
    chat = socket.assigns.chat
    GeneralChats.set(chat, web: !chat.web)
    {:noreply, assign(socket, chat: %{chat | web: !chat.web})}
  end

  def handle_event("cite", %{"turn" => turn, "n" => n}, socket) do
    cited = {turn, String.to_integer(n)}
    cited = if socket.assigns.cited == cited, do: nil, else: cited
    {:noreply, assign(socket, cited: cited, show_sources: true)}
  end

  def handle_event("toggle_sources", _params, socket),
    do: {:noreply, update(socket, :show_sources, &(!&1))}

  def handle_event("new_chat", _params, socket) do
    %{chats: chats, user_id: user_id, chat: current} = socket.assigns

    chat =
      Enum.find(chats, &(&1.started_at == nil)) ||
        GeneralChats.create_empty(user_id, model_opts(current))

    {:noreply,
     socket |> push_patch(to: ~p"/chats/#{chat.id}") |> push_event("composer:focus", %{})}
  end

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: q) |> search()}

  def handle_event("scope", %{"scope" => scope}, socket)
      when scope in ~w(chats project everywhere),
      do: {:noreply, socket |> assign(scope: scope) |> search()}

  def handle_event("dialog", %{"dialog" => "send"}, socket) do
    target = socket.assigns.rail |> List.first() |> then(&(&1 && &1.id))
    {:noreply, assign(socket, dialog: :send, target: target, dialog_error: nil)}
  end

  def handle_event("dialog", %{"dialog" => "start"}, socket),
    do:
      {:noreply,
       assign(socket, dialog: :start, pname: project_name(socket.assigns.chat), dialog_error: nil)}

  def handle_event("close_dialog", _params, socket), do: {:noreply, assign(socket, dialog: nil)}

  def handle_event("pick_target", %{"id" => id}, socket),
    do: {:noreply, assign(socket, target: String.to_integer(id), dialog_error: nil)}

  def handle_event("pname", %{"name" => name}, socket),
    do: {:noreply, assign(socket, pname: name, dialog_error: nil)}

  # A new chat in the project that starts from this one; nothing changes
  # there until the user sends.
  def handle_event("send_to_project", _params, socket) do
    %{current_scope: scope, chat: chat, target: target} = socket.assigns

    with id when is_integer(id) <- target,
         {:ok, project} <- fetch_project(scope, id),
         true <-
           Activity.room?(project, scope.user.id) ||
             {:error,
              "You have #{Chats.max()} changes open in #{project.name}. Merge or discard one there first."} do
      new = Chats.create_empty(project.id, scope.user, from_chat: chat.id)

      {:noreply,
       assign(socket,
         dialog: nil,
         notice: %{
           text: "New chat in #{project.name}, starting from this one.",
           url: ~p"/projects/#{project.id}/c/#{new.id}"
         }
       )}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, dialog_error: message)}

      _ ->
        {:noreply, assign(socket, dialog_error: "Pick a project.")}
    end
  end

  # A new project whose first chat starts from this one.
  def handle_event("start_project", %{"name" => name}, socket) do
    %{current_scope: scope, chat: chat} = socket.assigns

    case Projects.create(scope, %{"name" => String.trim(name)}) do
      {:ok, project} ->
        new = Chats.create_empty(project.id, scope.user, from_chat: chat.id)

        {:noreply,
         socket
         |> load_rail()
         |> assign(
           dialog: nil,
           notice: %{
             text: "Created #{project.name} with a chat that starts from this one.",
             url: ~p"/projects/#{project.id}/c/#{new.id}"
           }
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, pname: name, dialog_error: first_error(changeset))}
    end
  end

  def handle_event("close_notice", _params, socket), do: {:noreply, assign(socket, notice: nil)}

  @impl true
  def handle_info({:messages, messages}, socket),
    do: {:noreply, assign(socket, messages: messages, pending: nil)}

  def handle_info({:status, status}, %{assigns: %{info: nil}} = socket),
    do: {:noreply, assign(socket, info: Map.put(status, :messages, socket.assigns.messages))}

  def handle_info({:status, status}, socket),
    do: {:noreply, assign(socket, info: Map.merge(socket.assigns.info, status))}

  def handle_info({:stopped, _reason}, socket), do: {:noreply, assign(socket, info: nil)}

  def handle_info({:general_busy, id, busy?}, socket) do
    busy =
      if busy?,
        do: MapSet.put(socket.assigns.busy, id),
        else: MapSet.delete(socket.assigns.busy, id)

    {:noreply, assign(socket, busy: busy)}
  end

  def handle_info({event, _}, socket) when event in [:general_created, :general_deleted],
    do: {:noreply, socket |> load_chats() |> search()}

  # A title, or an answer and its pages, came in.
  def handle_info({:general_changed, id}, socket) do
    socket = socket |> load_chats() |> search()

    case socket.assigns.chat do
      %{id: ^id} = chat ->
        chat = GeneralChats.get(chat.id) || chat

        {:noreply,
         assign(socket, chat: chat, pages: GeneralChats.pages(chat), page_title: title(chat))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:rail_changed, socket), do: {:noreply, load_rail(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Loading

  defp load_chats(socket), do: assign(socket, chats: GeneralChats.list(socket.assigns.user_id))

  # Every project the user can open, with what it is doing (`Burrow.Activity`).
  defp load_rail(socket) do
    rail =
      for p <- Projects.list(socket.assigns.current_scope) do
        tile = Activity.of(p)

        %{
          id: p.id,
          name: p.name,
          url: ~p"/projects/#{p.id}",
          current: false,
          state: tile["state"],
          label: tile["label"],
          pct: tile["pct"]
        }
      end

    assign(socket, rail: rail)
  end

  # What the search box finds where the switch says: chats here, the last
  # project's chats, or both and every project's. Titles only.
  defp search(%{assigns: %{q: q}} = socket) do
    case String.trim(q) do
      "" ->
        assign(socket, found: [])

      text ->
        %{scope: where, user_id: user_id, current_scope: scope} = socket.assigns

        here =
          if where in ~w(chats everywhere),
            do: for(c <- GeneralChats.search(user_id, text), do: found_row(c)),
            else: []

        projects =
          case where do
            "chats" -> []
            "project" -> List.wrap(last_project(scope))
            "everywhere" -> Projects.list(scope)
          end

        there =
          for p <- projects,
              c <- Chats.list(p, scope.user.id),
              c.title != "",
              String.contains?(String.downcase(c.title), String.downcase(text)),
              do: %{id: c.id, title: c.title, sub: p.name, url: ~p"/projects/#{p.id}/c/#{c.id}"}

        assign(socket, found: here ++ Enum.reverse(there))
    end
  end

  defp found_row(chat),
    do: %{id: chat.id, title: title(chat), sub: "Chats", url: ~p"/chats/#{chat.id}"}

  defp last_project(%{user: %{last_project_id: id}} = scope) when is_integer(id) do
    case fetch_project(scope, id) do
      {:ok, project} -> project
      _ -> nil
    end
  end

  defp last_project(_scope), do: nil

  defp fetch_project(scope, id) do
    if Projects.visible?(scope, id),
      do: {:ok, Projects.get(id)},
      else: {:error, "Pick a project."}
  end

  # The box's files, kept with the chat under names of their own: `[%{name, mime}]`.
  defp take_files(socket, chat) do
    dir = GeneralChats.files_dir(chat)
    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
      ext = entry.client_name |> Path.extname() |> String.downcase()
      name = Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false) <> ext
      File.cp!(path, Path.join(dir, name))
      {:ok, %{name: name, mime: entry.client_type}}
    end)
  end

  defp look_text([_]), do: "Look at this file."
  defp look_text(_files), do: "Look at these files."

  # A new chat keeps the open one's model.
  defp model_opts(%GeneralChats.Chat{model: model, effort: effort}),
    do: [model: model, effort: effort]

  defp model_opts(_), do: []

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, &BurrowWeb.CoreComponents.translate_error/1)
         |> Enum.at(0) do
      {field, [message | _]} -> "#{Phoenix.Naming.humanize(field)} #{message}"
      _ -> "Could not create the project."
    end
  end

  defp send_error({:session, _}), do: "Peon could not start. Check your AI login under Account."
  defp send_error(:agent_boot_timeout), do: "Peon took too long to start. Try again."
  defp send_error(reason), do: "Could not send: #{inspect(reason)}"

  ## Words

  defp title(%{title: ""}), do: "New chat"
  defp title(%{title: title}), do: title

  # The name "Start a project from this" suggests: the chat's first words.
  defp project_name(%{title: title}) do
    title
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.split()
    |> Enum.take(4)
    |> Enum.join(" ")
    |> String.slice(0, 40)
    |> case do
      "" -> "New project"
      name -> name
    end
  end

  @days ["Today", "Yesterday", "This week", "Older"]

  # Started chats by the day of their latest answer; an empty one only while open.
  defp history(chats, current) do
    chats
    |> Enum.filter(&(&1.started_at != nil or (current != nil and &1.id == current.id)))
    |> Enum.group_by(&day(&1.updated_at))
    |> Enum.sort_by(fn {day, _} -> Enum.find_index(@days, &(&1 == day)) end)
  end

  defp day(at) do
    case Date.diff(Date.utc_today(), DateTime.to_date(at)) do
      n when n <= 0 -> "Today"
      1 -> "Yesterday"
      n when n < 7 -> "This week"
      _ -> "Older"
    end
  end

  defp sub(%{started_at: nil}, _busy?), do: "empty"
  defp sub(_chat, true), do: "searching…"

  defp sub(chat, false) do
    sources =
      case chat.sources do
        0 -> "no sources"
        1 -> "1 source"
        n -> "#{n} sources"
      end

    if day(chat.updated_at) == "Today",
      do: "#{sources} · #{Calendar.strftime(chat.updated_at, "%H:%M")}",
      else: sources
  end

  ## The thread

  # The conversation as turns: `{:user, message}` and `{:peon, turn}`, where a
  # turn has its `id` (the user's message it answers), whether Peon searched
  # the web, its answer without the sources block, the sources, and errors.
  defp turns(messages, pages, live_pages, busy?) do
    groups =
      Enum.chunk_while(
        messages,
        nil,
        fn
          %{role: :user} = m, nil -> {:cont, {m, []}}
          %{role: :user} = m, acc -> {:cont, acc, {m, []}}
          m, nil -> {:cont, {nil, [m]}}
          m, {u, ms} -> {:cont, {u, [m | ms]}}
        end,
        fn
          nil -> {:cont, nil}
          acc -> {:cont, acc, nil}
        end
      )

    last = length(groups) - 1

    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {{user, ms}, i} ->
      ms = Enum.reverse(ms)
      id = (user && user.id) || "start"
      live? = busy? and i == last
      turn_pages = if live?, do: live_pages, else: Map.get(pages, id, [])
      peon = peon_turn(id, ms, turn_pages, live?)
      if(user, do: [{:user, user}], else: []) ++ if(peon, do: [{:peon, peon}], else: [])
    end)
  end

  defp peon_turn(id, messages, pages, live?) do
    searched? =
      Enum.any?(
        messages,
        &(&1.role == :tool and String.starts_with?(&1.text, ["websearch", "webfetch"]))
      )

    # The answer: what Peon said after its last look at the web.
    after_tools =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(&1.role != :tool))
      |> Enum.reverse()

    text =
      after_tools
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.map_join("\n\n", & &1.text)

    {answer, cited} = Sources.split(text)
    titles = Map.new(pages, &{&1.url, &1.title})

    sources =
      case cited do
        [] -> if(searched? and not live?, do: Sources.fallback(pages), else: [])
        cited -> Enum.map(cited, &with_title(&1, titles))
      end

    errors = Enum.filter(messages, &(&1.role == :error))

    if answer == "" and errors == [] and not live? and not searched?,
      do: nil,
      else: %{
        id: id,
        searched?: searched?,
        live?: live?,
        answer: answer,
        sources: sources,
        pages: pages,
        errors: errors
      }
  end

  # A source the answer names by its link only takes the title the search found.
  defp with_title(%{title: title, site: site, url: url} = source, titles) when title == site,
    do: %{source | title: titles[url] || title}

  defp with_title(source, _titles), do: source

  # The sources pane: the picked citation's turn, else the latest that has some.
  defp pane(turns, cited) do
    peon = for {:peon, t} <- turns, do: t

    turn =
      case cited do
        {id, _n} -> Enum.find(peon, &(&1.id == id))
        nil -> nil
      end || Enum.find(Enum.reverse(peon), &(&1.live? or &1.sources != []))

    case turn do
      nil ->
        %{turn: nil, sources: [], live?: false}

      %{live?: true, sources: []} = t ->
        %{turn: t.id, sources: live_sources(t.pages), live?: true}

      t ->
        %{turn: t.id, sources: t.sources, live?: t.live?}
    end
  end

  defp live_sources(pages) do
    for {page, i} <- Enum.with_index(pages, 1),
        do: %{n: i, title: page.title || page.site, url: page.url, site: page.site, quote: nil}
  end

  defp cites(sources), do: MapSet.new(sources, & &1.n)

  # Peon's voice while it works, as in Warcraft III.
  defp looking([]), do: "Me look around."
  defp looking(_pages), do: "Me read."

  defp found_text([]), do: "searching the web"
  defp found_text([_]), do: "1 source so far"
  defp found_text(pages), do: "#{length(pages)} sources so far"

  defp sources_text(1), do: "1 source"
  defp sources_text(n), do: "#{n} sources"

  defp file_error(:too_large), do: "Files can be at most 10 MB."
  defp file_error(:too_many_files), do: "At most 4 files at once."
  defp file_error(:not_accepted), do: "Images, PDFs and text files only."
  defp file_error(error), do: "That file didn't upload: #{error}"

  @impl true
  def render(assigns) do
    busy? = assigns.info != nil and assigns.info.busy?

    turns =
      turns(assigns.messages, assigns.pages, (assigns.info && assigns.info[:pages]) || [], busy?)

    assigns =
      assign(assigns,
        busy?: busy?,
        turns: turns,
        pane: pane(turns, assigns.cited),
        started?: assigns.messages != [] or assigns.pending != nil,
        history: history(assigns.chats, assigns.chat),
        target_project: Enum.find(assigns.rail, &(&1.id == assigns.target))
      )

    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="ws-root gc-root">
      <div
        class="ws-scrim"
        aria-hidden="true"
        phx-click={JS.remove_class("show-drawer", to: ".ws-root")}
      >
      </div>
      <nav
        id="drawer"
        class="drawer"
        aria-label="Chats and projects"
        phx-hook=".Drawer"
        data-kb-zoom-hide
      >
        <div class="dlist">
          <div class="dtop">
            <button
              id="space-switch"
              type="button"
              class="swt"
              aria-label="Switch place. Now Chats"
              title="Switch place (⌃B P)"
              phx-click={JS.add_class("switching", to: "#drawer")}
              data-kb-key="P"
              data-kb-label="Switch place"
              data-kb-group="Projects"
            >
              <span class="av"><.icon name="hero-chat-bubble-bottom-center" class="size-[18px]" /></span>
              <span class="pn">
                <span class="nm">Chats</span><span class="mm">Ask, search, think · no project</span>
              </span>
              <.icon name="hero-chevron-up-down" class="size-4 shrink-0 pchev" />
            </button>
          </div>
          <form
            id="chat-search"
            class="gc-search"
            phx-change="search"
            phx-submit="search"
            role="search"
          >
            <label class="gc-sbox">
              <.icon name="hero-magnifying-glass" class="size-[14px] shrink-0" />
              <span class="sr-only">Search chats</span>
              <input
                type="search"
                name="q"
                value={@q}
                placeholder="Search"
                autocomplete="off"
                phx-debounce="200"
              />
            </label>
            <div class="gc-scope" role="group" aria-label="Search in">
              <button
                :for={
                  {scope, label} <- [
                    {"chats", "Chats"},
                    {"project", "This project"},
                    {"everywhere", "Everywhere"}
                  ]
                }
                type="button"
                aria-pressed={to_string(@scope == scope)}
                phx-click="scope"
                phx-value-scope={scope}
              >
                {label}
              </button>
            </div>
          </form>
          <span class="ncw">
            <button
              id="new-chat"
              type="button"
              class="newchat"
              phx-click="new_chat"
              data-kb-key="c"
              data-kb-label="New chat"
              data-kb-group="Chats"
              data-kb-focus="#chat-input"
            >
              <.icon name="hero-plus" class="size-4 shrink-0" /><span class="dt">New chat</span><kbd>⌃B C</kbd>
            </button>
          </span>
          <div class="dscroll">
            <%= if String.trim(@q) != "" do %>
              <div class="dsec"><span>Found</span></div>
              <div
                :for={f <- @found}
                class="crow"
                data-on={to_string(@chat != nil and @chat.id == f.id)}
              >
                <.link
                  :if={String.starts_with?(f.url, "/chats/")}
                  patch={f.url}
                  class="crb"
                  data-kb="item"
                >
                  <span class="cb"><span class="ct"><span class="tt">{f.title}</span></span><span class="cs2">{f.sub}</span></span>
                </.link>
                <.link
                  :if={!String.starts_with?(f.url, "/chats/")}
                  navigate={f.url}
                  class="crb"
                  data-kb="item"
                >
                  <span class="cb"><span class="ct"><span class="tt">{f.title}</span></span><span class="cs2">{f.sub}</span></span>
                </.link>
              </div>
              <p :if={@found == []} class="dnone">No chats match.</p>
            <% else %>
              <div :for={{day, chats} <- @history} class="dday">
                <div class="dsec"><span>{day}</span></div>
                <div
                  :for={c <- chats}
                  id={"gchat-#{c.id}"}
                  class="crow"
                  data-on={to_string(@chat != nil and @chat.id == c.id)}
                >
                  <.link
                    patch={~p"/chats/#{c.id}"}
                    class="crb"
                    aria-current={(@chat != nil and @chat.id == c.id) && "page"}
                    data-kb="item"
                    title={title(c)}
                  >
                    <span :if={MapSet.member?(@busy, c.id)} class="cdot working" aria-hidden="true"></span>
                    <span class="cb">
                      <span class="ct"><span class="tt">{title(c)}</span></span>
                      <span class="cs2">{sub(c, MapSet.member?(@busy, c.id))}</span>
                    </span>
                  </.link>
                </div>
              </div>
            <% end %>
          </div>
          <.account_menu user={@current_scope.user} />
        </div>
        <div class="dswitch">
          <.place_switch
            rail={@rail}
            chats?={true}
            back={JS.remove_class("switching", to: "#drawer")}
            new_project={JS.navigate(~p"/projects?new")}
          />
        </div>
      </nav>
      <div id="theme" phx-hook=".Theme" data-theme={@theme} hidden></div>
      <.rail new_chat={JS.push("new_chat")} />

      <div class="ws-main">
        <div class="pbar">
          <button
            type="button"
            class="icon-btn pbar-menu"
            aria-label="Chats and projects"
            phx-click={JS.add_class("show-drawer", to: ".ws-root")}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <div class="pbar-title">
            <h1 class="pbar-name"><span class="pbar-t">{@chat && title(@chat)}</span></h1>
          </div>
          <div class="pbar-acts">
            <button
              :if={@messages != []}
              id="start-project"
              type="button"
              class="btn btn-secondary btn-sm gc-wide"
              phx-click="dialog"
              phx-value-dialog="start"
            >
              Start a project from this
            </button>
            <button
              :if={@messages != []}
              id="send-to-project"
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="dialog"
              phx-value-dialog="send"
              data-kb-key="s"
              data-kb-label="Send to a project"
              data-kb-group="Chats"
            >
              <span class="gc-wide">Send to a project…</span><span class="gc-narrow">Send…</span>
            </button>
            <button
              type="button"
              class="icon-btn gc-srcbtn"
              aria-label={if @show_sources, do: "Hide sources", else: "Show sources"}
              title={if @show_sources, do: "Hide sources", else: "Show sources"}
              aria-pressed={to_string(@show_sources)}
              phx-click="toggle_sources"
            >
              <.icon name="hero-view-columns" class="size-4" />
            </button>
          </div>
        </div>

        <div class="ws-split">
          <main class="ws-chat gc-chat" aria-label="Chat" data-kb-zoom-hide>
            <div class="ws-scroll" id="messages" phx-hook=".ScrollBottom">
              <div class="ws-thread gc-thread">
                <div :if={!@started?} class="ws-hello">
                  <Layouts.mark size={52} />
                  <h2>What do you want to know?</h2>
                  <p>No project, no code. Peon searches the web and answers.</p>
                </div>
                <%= for t <- @turns do %>
                  <%= case t do %>
                    <% {:user, m} -> %>
                      <div
                        :if={m[:images] not in [nil, []]}
                        class="bubble-imgs"
                      >
                        <a
                          :for={name <- m.images}
                          href={~p"/chats/#{@chat.id}/files/#{name}"}
                          target="_blank"
                        >
                          <img
                            src={~p"/chats/#{@chat.id}/files/#{name}"}
                            alt="An image sent with the message"
                            loading="lazy"
                          />
                        </a>
                      </div>
                      <div class="bubble-user">{m.text}</div>
                    <% {:peon, turn} -> %>
                      <div class="say-peon-turn" id={"turn-#{turn.id}"}>
                        <Layouts.mark size={28} />
                        <div class="flex-1 min-w-0 flex flex-col gap-2.5">
                          <div class="text-[13px] font-semibold leading-[18px]">Peon</div>
                          <div :if={turn.live?} class="gc-looking" role="status">
                            <canvas
                              id={"look-#{turn.id}"}
                              class="gc-look"
                              phx-hook=".PeonLook"
                              phx-update="ignore"
                              width="144"
                              height="34"
                              aria-hidden="true"
                            ></canvas>
                            <div class="ws-working">
                              <span class="font-medium shrink-0">{looking(turn.pages)}</span>
                              <span class="mono muted text-[12.5px] truncate">{found_text(turn.pages)}</span>
                              <button
                                type="button"
                                phx-click="interrupt"
                                data-kb-key="x"
                                data-kb-label="Stop Peon"
                                data-kb-group="Chats"
                                data-kb-esc
                                class="btn btn-ghost btn-sm ml-auto"
                              >
                                Stop
                              </button>
                            </div>
                          </div>
                          <div :if={turn.searched? and !turn.live?} class="gc-searched">
                            <.icon name="hero-globe-alt" class="size-[14px]" />
                            Searched the web<span :if={turn.sources != []}> · {sources_text(
                              length(turn.sources)
                            )}</span>
                          </div>
                          <.markdown
                            :if={turn.answer != ""}
                            text={turn.answer}
                            cites={cites(turn.sources)}
                            turn={turn.id}
                            cited={@cited}
                          />
                          <div :for={e <- turn.errors} class="say-error">{e.text}</div>
                        </div>
                      </div>
                  <% end %>
                <% end %>
                <div :if={@pending} class="bubble-user opacity-60">{@pending}</div>
                <div :if={@pending && !@busy?} class="ws-working" role="status">
                  <.icon name="hero-arrow-path" class="size-4 spin" />
                  {if @info, do: "Sending…", else: "Waking Peon…"}
                </div>
                <div :if={@start_error} class="say-error">{@start_error}</div>
              </div>
            </div>

            <div class="ws-bottom gc-bottom">
              <div :if={@notice} id="notice" class="gc-notice" role="status">
                <.icon name="hero-arrow-uturn-right" class="size-4 shrink-0" />
                <span>{@notice.text}</span>
                <.link navigate={@notice.url} class="btn btn-secondary btn-sm">Open it</.link>
                <button type="button" class="cx" phx-click="close_notice" aria-label="Dismiss">
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
              <.form
                for={@form}
                id="composer"
                phx-submit="send"
                phx-change="typing"
                phx-drop-target={@uploads.files.ref}
                class="composer"
              >
                <div :if={@uploads.files.entries != []} id="composer-files" class="shots">
                  <div :for={entry <- @uploads.files.entries} class="shot">
                    <.live_img_preview
                      :if={String.starts_with?(entry.client_type, "image/")}
                      entry={entry}
                    />
                    <span :if={!String.starts_with?(entry.client_type, "image/")} class="gc-file mono">
                      {entry.client_name}
                    </span>
                    <button
                      type="button"
                      class="cx"
                      phx-click="cancel_file"
                      phx-value-ref={entry.ref}
                      aria-label={"Remove #{entry.client_name}"}
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                    <span :for={err <- upload_errors(@uploads.files, entry)} class="err">
                      {file_error(err)}
                    </span>
                  </div>
                </div>
                <p :for={err <- upload_errors(@uploads.files)} class="say-error">{file_error(err)}</p>
                <label class="sr-only" for="chat-input">Message Peon</label>
                <textarea
                  name="text"
                  rows="2"
                  id="chat-input"
                  data-kb="search"
                  data-kb-label="Chat box"
                  phx-hook=".SubmitOnEnter"
                  placeholder="Ask anything"
                >{@form[:text].value}</textarea>
                <div class="cbar">
                  <button
                    :if={@chat}
                    id="web-toggle"
                    type="button"
                    class="gc-tg"
                    aria-pressed={to_string(@chat.web)}
                    phx-click="toggle_web"
                    title={
                      if @chat.web,
                        do: "Peon may search the web",
                        else: "Peon answers from what it knows"
                    }
                  >
                    <.icon name="hero-globe-alt" class="size-[14px]" />Web search
                  </button>
                  <label class="icon-btn sm" title="Attach a file (or paste an image)">
                    <span class="sr-only">Attach a file</span>
                    <.icon name="hero-paper-clip" class="size-4" />
                    <.live_file_input upload={@uploads.files} class="sr-only" />
                  </label>
                  <.model_pick :if={@chat} chat={@chat} models={@models} default={@default_model} />
                  <button class="icon-btn ws-send" aria-label="Send" disabled={@sending}>
                    <.icon name="hero-arrow-up" class="size-4" />
                  </button>
                </div>
              </.form>
            </div>
          </main>

          <aside :if={@show_sources} class="gc-src" aria-label="Sources">
            <div class="gc-srchead">
              <span class="font-semibold">Sources</span>
              <span :if={@pane.sources != []} class="mono gc-count">{length(@pane.sources)}</span>
            </div>
            <div class="gc-srclist">
              <a
                :for={s <- @pane.sources}
                href={s.url}
                target="_blank"
                rel="noopener noreferrer"
                class="gc-card"
                data-on={to_string(@cited == {@pane.turn, s.n})}
                id={"source-#{@pane.turn}-#{s.n}"}
              >
                <span class="n mono">{s.n}</span>
                <span class="t">{s.title}</span>
                <span class="d mono">{s.site}</span>
                <span :if={s.quote} class="q">{s.quote}</span>
              </a>
              <div :if={@pane.live?} class="gc-card ghost">
                <span class="n mono">…</span><span class="t">Reading more</span>
              </div>
              <p :if={@pane.sources == [] and !@pane.live?} class="gc-none">
                Sources Peon reads show up here.
              </p>
            </div>
          </aside>
        </div>
      </div>

      <div :if={@dialog} class="ovl" phx-window-keydown="close_dialog" phx-key="Escape">
        <.form
          :if={@dialog == :send}
          for={%{}}
          id="send-dialog"
          class="modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="send-title"
          phx-submit="send_to_project"
          phx-click-away="close_dialog"
        >
          <h2 id="send-title" class="m-0 text-lg font-semibold">Send to a project</h2>
          <div role="radiogroup" aria-label="Project" class="gc-prjs">
            <button
              :for={p <- @rail}
              type="button"
              role="radio"
              class="gc-prj"
              aria-checked={to_string(p.id == @target)}
              phx-click="pick_target"
              phx-value-id={p.id}
            >
              <span class="rd" aria-hidden="true"></span>
              <span class="flex-1 min-w-0 truncate">{p.name}</span>
              <span class={["lbl", p.state]}>{p.label}</span>
            </button>
            <p :if={@rail == []} class="muted text-sm">
              No projects yet. Start one from this chat instead.
            </p>
          </div>
          <span class="gc-ctx">↳ from Chats: {@chat && title(@chat)}</span>
          <p class="m-0 text-[13.5px] leading-5 text-[var(--text-2)]">
            Opens a new chat in {(@target_project && @target_project.name) || "the project"} with this conversation as context. Nothing changes until you send.
          </p>
          <p :if={@dialog_error} class="say-error m-0">{@dialog_error}</p>
          <div class="flex items-center justify-end gap-2 flex-wrap">
            <button
              type="button"
              class="btn btn-ghost mr-auto"
              phx-click="dialog"
              phx-value-dialog="start"
            >
              Start a new project instead
            </button>
            <button type="button" class="btn btn-ghost" phx-click="close_dialog">Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={@target_project == nil}>
              Open chat in {(@target_project && @target_project.name) || "…"}
            </button>
          </div>
        </.form>
        <.form
          :if={@dialog == :start}
          for={%{}}
          id="start-dialog"
          class="modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="start-title"
          phx-submit="start_project"
          phx-change="pname"
          phx-click-away="close_dialog"
        >
          <h2 id="start-title" class="m-0 text-lg font-semibold">Start a project from this chat</h2>
          <div>
            <label for="project-name" class="block mb-1.5 text-[13px] font-medium">Project name</label>
            <input
              id="project-name"
              name="name"
              type="text"
              value={@pname}
              class="field"
              autocomplete="off"
              phx-mounted={JS.focus()}
            />
          </div>
          <span class="gc-ctx">↳ from Chats: {@chat && title(@chat)}</span>
          <p class="m-0 text-[13.5px] leading-5 text-[var(--text-2)]">
            Creates the project and opens its first chat with this conversation as context. This chat stays in Chats.
          </p>
          <p :if={@dialog_error} class="say-error m-0">{@dialog_error}</p>
          <div class="flex justify-end gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close_dialog">Cancel</button>
            <button type="submit" class="btn btn-primary">Create and open</button>
          </div>
        </.form>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Drawer">
      // Picking a chat or a place puts the drawer away (a patch link stops
      // LiveView's own phx-click).
      export default {
        mounted() {
          this.el.addEventListener("click", e => {
            if (e.target.closest("a")) this.js().removeClass(this.el.closest(".ws-root"), "show-drawer")
          })
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Theme">
      // The user's theme on <html>; Burrow keeps it for the next page load.
      export default {
        mounted() { this.apply() },
        updated() { this.apply() },
        apply() { document.documentElement.dataset.theme = this.el.dataset.theme }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollBottom">
      export default {
        mounted() { this.el.scrollTop = this.el.scrollHeight },
        updated() { this.el.scrollTop = this.el.scrollHeight }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
      export default {
        mounted() {
          this.handleEvent("composer:focus", () => this.el.focus())
          this.handleEvent("composer:put", ({text}) => {
            this.el.value = text
            this.el.focus()
          })
          // Pasted images go with the message
          this.el.addEventListener("paste", e => {
            const files = [...(e.clipboardData?.files || [])].filter(f => f.type.startsWith("image/"))
            if (files.length) { e.preventDefault(); this.upload("files", files) }
          })
          this.el.addEventListener("keydown", e => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              this.el.form.requestSubmit()
              if (!document.querySelector("#composer-files .shot")) this.el.value = ""
            }
          })
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PeonLook">
      // The peon with a spyglass walks between two pages while it searches.
      export default {
        mounted() {
          const canvas = this.el, W = 72, H = 17, S = 2, GY = 16
          const ctx = canvas.getContext("2d")
          ctx.imageSmoothingEnabled = false
          const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
          const px = (x, y, w, h, c) => { ctx.fillStyle = c; ctx.fillRect(Math.round(x), Math.round(y), w, h) }
          const ground = () => getComputedStyle(canvas).getPropertyValue("--text-3").trim() || "#938A82"
          let frame = 0, raf = 0, line = ground()
          const draw = () => {
            ctx.setTransform(S, 0, 0, S, 0, 0)
            ctx.clearRect(0, 0, W, H)
            px(4, GY, 64, 1, line)
            const dir = Math.floor(frame / 50) % 2 ? 1 : -1
            const x = 36 + Math.round(Math.sin(frame / 40) * 10)
            const sx = x - 4, sy = GY - 9
            px(sx + 1, sy, 6, 1, "#8FBF5A"); px(sx, sy + 1, 8, 6, "#8FBF5A"); px(sx + 1, sy + 7, 6, 1, "#8FBF5A"); px(sx, sy + 6, 8, 1, "#6E9B3D")
            const o = dir > 0 ? 1 : 0
            px(sx + 1 + o, sy + 2, 1, 1, "#1C2412"); px(sx + 5 + o, sy + 2, 1, 1, "#1C2412")
            px(sx + 1 + o, sy + 5, 1, 2, "#F7F4EA"); px(sx + 5 + o, sy + 5, 1, 2, "#F7F4EA")
            const leg = (frame >> 3) % 2
            px(sx + 2 - leg, sy + 8, 1, 1, "#1C2412"); px(sx + 5 + leg, sy + 8, 1, 1, "#1C2412")
            if (dir > 0) { px(sx + 8, sy + 2, 4, 1, "#C9CED6"); px(sx + 12, sy + 1, 1, 3, "#C9CED6") }
            else { px(sx - 4, sy + 2, 4, 1, "#C9CED6"); px(sx - 5, sy + 1, 1, 3, "#C9CED6") }
            ;[10, 58].forEach((x0, i) => {
              px(x0, GY - 7, 6, 7, "#FFFFFF")
              for (let r = 0; r < 3; r++) px(x0 + 1, GY - 6 + r * 2, 4, 1, i ? "#2F5BD3" : "#C9CED6")
            })
          }
          const tick = () => { frame += 1; if (frame % 120 === 0) line = ground(); draw(); raf = requestAnimationFrame(tick) }
          if (reduce) draw(); else raf = requestAnimationFrame(tick)
          this.stop = () => cancelAnimationFrame(raf)
        },
        destroyed() { this.stop && this.stop() }
      }
    </script>
    """
  end
end
