defmodule BurrowWeb.WorkspaceLive.Components do
  @moduledoc """
  The workspace's parts (`BurrowWeb.WorkspaceLive`): the chat drawer with
  the project switcher, the bar over the chat, the change card, the preview
  pane, "Deploys and usage", and the dialogs.
  """

  use BurrowWeb, :html

  alias Burrow.{Activity, Chats}

  ## Chat drawer

  attr :rail, :list, required: true, doc: "every project the user can open"
  attr :status, :string, required: true, doc: "the line under the project's name"
  attr :tabs, :list, required: true, doc: "the project's chats (`Burrow.Activity.chats/2`)"
  attr :chat, :map
  attr :project, :map
  attr :base, :string, required: true, doc: "the workspace's path"
  attr :folded, :list, required: true, doc: "the day groups folded to their open chats"
  attr :user, :map, required: true, doc: "the signed-in user, for the account menu"
  attr :nothing_built?, :boolean, required: true
  attr :repo?, :boolean, required: true
  attr :live_only?, :boolean, required: true
  attr :peek, :map, default: nil, doc: "another place whose chats show instead (`BurrowWeb.Peek`)"

  @doc """
  Chats and projects, over the page (the rail's drawer button, ≡ on
  phones). On top All projects, then the place, the project: it turns into
  \"Switch to\" (Chats, every project, All projects, New project), and
  picking one there lists its chats here instead (`BurrowWeb.Peek`). Then a
  search over the chats, New chat and the chats by the day they were worked
  on, the last first; a day before today folds to the chats still open (and
  the one shown). At the bottom the account: teams, AI login, logins, the
  theme, log out.
  """
  def drawer(assigns) do
    open = open_chats(assigns.tabs, assigns.live_only?)

    assigns =
      assign(assigns,
        open: length(open),
        days: by_day(assigns.tabs, assigns.live_only?),
        tile: Enum.find(assigns.rail, & &1.current) || %{state: "stopped", pct: 8}
      )

    ~H"""
    <nav
      id="drawer"
      class="drawer"
      aria-label="Chats and projects"
      phx-hook=".Drawer"
      data-kb-zoom-hide
    >
      <div class="dlist">
        <.all_projects />
        <div :if={!@peek} class="dtop">
          <button
            id="project-switch"
            type="button"
            class="swt"
            aria-label={"Switch project. Now #{@project.name}"}
            title="Switch project (⌃B P)"
            phx-click={JS.add_class("switching", to: "#drawer")}
            data-kb-key="P"
            data-kb-label="Switch project"
            data-kb-group="Projects"
          >
            <.tile name={@project.name} state={@tile.state} pct={@tile.pct} />
            <span class="pn">
              <span class="nm">{@project.name}</span><span class="mm">{@status}</span>
            </span>
            <.icon name="hero-chevron-up-down" class="size-4 shrink-0 pchev" />
          </button>
        </div>
        <label :if={!@peek} class="dsearch">
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
          <span class="sr-only">Search the chats</span>
          <input
            id="chat-search"
            type="search"
            placeholder={"Search #{@project.name}"}
            autocomplete="off"
          />
        </label>
        <span :if={!@peek} class="ncw" title="New chat (⌃B C)">
          <button
            id="new-chat"
            type="button"
            class="newchat"
            aria-label="New chat"
            phx-click="new_chat"
            data-kb-key="c"
            data-kb-label="New chat"
            data-kb-group="Chats"
            data-kb-focus="#chat-input"
          >
            <.icon name="hero-plus" class="size-[18px] shrink-0" /><span class="dt">New chat</span><kbd>⌃B C</kbd>
          </button>
        </span>
        <div :if={!@peek} class="dscroll">
          <div
            :for={{{day, tabs, done}, i} <- Enum.with_index(@days)}
            id={"day-" <> String.replace(String.downcase(day), " ", "-")}
            class={["dday", day in @folded && "folded"]}
          >
            <div class="dsec">
              <button
                :if={day != "Today" and done > 0}
                type="button"
                class="dfold"
                phx-click="fold_day"
                phx-value-day={day}
                aria-expanded={to_string(day not in @folded)}
                title={if day in @folded, do: "Show the done chats", else: "Show only the open chats"}
              >
                {day}<.icon name="hero-chevron-down" class="size-3 dchev" /><span
                  :if={day in @folded}
                  class="dn"
                >{done} done</span>
              </button>
              <span :if={day == "Today" or done == 0}>{day}</span>
              <button
                :if={i == 0 and @open > 0}
                id="drawer-edit"
                type="button"
                class="dedit"
                aria-pressed="false"
                phx-click={
                  JS.toggle_class("editing", to: "#drawer")
                  |> JS.toggle_attribute({"aria-pressed", "true", "false"})
                }
              >
                <span class="off">Edit</span><span class="on">Done</span>
              </button>
            </div>
            <.chat_row
              :for={t <- tabs}
              tab={t}
              url={"#{@base}/c/#{t.chat.id}"}
              current={@chat != nil and @chat.id == t.chat.id}
              title={chat_title(t, @project, @nothing_built?)}
              status={row_status(t, @live_only?)}
              meta={row_meta(t)}
              confirm={close_confirm(t, @repo?)}
              done={Activity.done?(t, @live_only?)}
            />
          </div>
          <p class="dnone">No chats match.</p>
        </div>
        <.peek_list :if={@peek} peek={@peek} />
        <.account_menu user={@user} />
      </div>
      <div class="dswitch">
        <.place_switch
          rail={@rail}
          shown={(@peek && @peek.id) || @project.id}
          back={JS.remove_class("switching", to: "#drawer")}
          new_project={
            JS.remove_class("show-drawer switching", to: ".ws-root, #drawer")
            |> JS.push("dialog", value: %{dialog: "new_project"})
          }
        />
      </div>
    </nav>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Drawer">
      // Picking a chat or a place puts the drawer away (a patch link stops
      // LiveView's own phx-click). The search box hides the chats whose
      // title doesn't match, again after every update.
      export default {
        mounted() {
          this.query = ""
          this.el.addEventListener("click", e => {
            if (e.target.closest("a")) this.js().removeClass(this.el.closest(".ws-root"), "show-drawer")
          })
          this.el.addEventListener("input", e => {
            if (e.target.id !== "chat-search") return
            this.query = e.target.value.trim().toLowerCase()
            this.filter()
          })
          this.filter()
        },
        updated() { this.filter() },
        filter() {
          const q = this.query
          this.el.classList.toggle("searching", q !== "")
          let any = false
          this.el.querySelectorAll(".crow").forEach(row => {
            const hit = !q || row.querySelector(".tt").textContent.toLowerCase().includes(q)
            row.classList.toggle("miss", !hit)
            any = any || hit
          })
          this.el.querySelectorAll(".dday").forEach(day => day.classList.toggle("miss", !day.querySelector(".crow:not(.miss)")))
          this.el.classList.toggle("none", q !== "" && !any)
        }
      }
    </script>
    """
  end

  attr :rail, :list,
    required: true,
    doc: "every project the user can open, as the drawer has them"

  attr :shown, :any,
    required: true,
    doc: "the place the drawer lists: a project's id or \"chats\""

  attr :back, :any, default: nil, doc: "the back button's JS; none hides it"
  attr :new_project, :any, required: true, doc: "New project's JS"

  @doc """
  \"Switch to\": Chats (general chats, no project), every project with what
  it is doing, All projects and New project. Picking a place lists its
  chats in the drawer (\"peek\", `BurrowWeb.Peek`); the one listed is checked.
  """
  def place_switch(assigns) do
    assigns = assign(assigns, shown: to_string(assigns.shown))

    ~H"""
    <div class="swhead">
      <button
        :if={@back}
        type="button"
        class="icon-btn"
        aria-label="Back to the chats"
        phx-click={@back}
      >
        <.icon name="hero-chevron-left" class="size-5" />
      </button>
      <span>Switch to</span>
    </div>
    <div class="swlist">
      <button
        id="switch-chats"
        type="button"
        class="swt"
        aria-current={to_string(@shown == "chats")}
        phx-click={peek("chats")}
        data-kb-key="0"
        data-kb-label="Chats"
        data-kb-group="Projects"
      >
        <span class="av"><.icon name="hero-chat-bubble-bottom-center" class="size-[18px]" /></span>
        <span class="pn"><span class="nm">Chats</span><span class="mm">Ask, search, think · no project</span></span>
        <.icon :if={@shown == "chats"} name="hero-check" class="size-4 shrink-0 swcheck" />
      </button>
      <div class="h">Projects</div>
      <button
        :for={p <- @rail}
        id={"switch-#{p.id}"}
        type="button"
        class="swt"
        aria-current={to_string(@shown == to_string(p.id))}
        phx-click={peek(p.id)}
      >
        <.tile name={p.name} state={p.state} pct={p.pct} />
        <span class="pn">
          <span class="nm">{p.name}</span>
          <span class={["lbl", p.state]}><span class="dot"></span>{p.label}</span>
        </span>
        <.icon :if={@shown == to_string(p.id)} name="hero-check" class="size-4 shrink-0 swcheck" />
      </button>
      <div class="msep" role="separator"></div>
      <.link navigate={~p"/projects"} class="mi">
        <.icon name="hero-squares-2x2" class="size-[18px]" /><span class="flex-1">All projects</span>
        <.icon name="hero-chevron-right" class="size-3.5 muted" />
      </.link>
      <button
        id="new-project-btn"
        type="button"
        class="mi"
        aria-haspopup="dialog"
        phx-click={@new_project}
        data-kb-key="N"
        data-kb-label="New project"
        data-kb-group="Projects"
      >
        <.icon name="hero-plus" class="size-[18px]" /><span class="flex-1">New project</span>
      </button>
    </div>
    """
  end

  @doc "Lists a place's chats in the drawer (\"peek\"), opening it if it is away."
  def peek(place),
    do:
      JS.push("peek", value: %{place: place})
      |> JS.remove_class("switching", to: "#drawer")
      |> JS.add_class("show-drawer", to: ".ws-root")

  attr :current, :boolean, default: false, doc: "the projects page is the page"

  @doc "All projects, on top of the drawer."
  def all_projects(assigns) do
    ~H"""
    <div class="dhome">
      <.link navigate={~p"/projects"} class="mi" aria-current={@current && "page"}>
        <.icon name="hero-squares-2x2" class="size-[18px]" /><span class="flex-1">All projects</span>
      </.link>
    </div>
    """
  end

  attr :peek, :map, required: true, doc: "the place, as `BurrowWeb.Peek.load/3` has it"

  @doc """
  Another place's chats in the drawer: the place on top (it turns into
  \"Switch to\"), a search, New chat there, and its chats by day, each a
  link into it.
  """
  def peek_list(assigns) do
    ~H"""
    <div id="peek" class="peek" phx-hook=".Peek">
      <div class="dtop">
        <button
          id="peek-switch"
          type="button"
          class="swt"
          aria-label={"Switch place. Now #{@peek.name}"}
          phx-click={JS.add_class("switching", to: "#drawer")}
        >
          <.tile :if={@peek.tile} name={@peek.name} state={@peek.tile.state} pct={@peek.tile.pct} />
          <span :if={!@peek.tile} class="av">
            <.icon name="hero-chat-bubble-bottom-center" class="size-[18px]" />
          </span>
          <span class="pn"><span class="nm">{@peek.name}</span><span class="mm">{@peek.sub}</span></span>
          <.icon name="hero-chevron-up-down" class="size-4 shrink-0 pchev" />
        </button>
      </div>
      <label class="dsearch">
        <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
        <span class="sr-only">Search the chats</span>
        <input id="peek-search" type="search" placeholder={"Search #{@peek.name}"} autocomplete="off" />
      </label>
      <span class="ncw">
        <.link id="peek-new" navigate={@peek.new_url} class="newchat">
          <.icon name="hero-plus" class="size-[18px] shrink-0" /><span class="dt">New chat</span>
        </.link>
      </span>
      <div class="dscroll">
        <div :for={{day, rows} <- @peek.days} class="dday">
          <div class="dsec"><span>{day}</span></div>
          <div :for={r <- rows} id={"peek-#{r.id}"} class={["crow", r.done? && "past"]}>
            <.link navigate={r.url} class="crb" data-kb="item" title={r.title}>
              <span class="cb">
                <span class="ct"><span class="tt">{r.title}</span></span>
                <span class="cs2">
                  <span :if={r.status} class={["cst", elem(r.status, 1)]}>{elem(r.status, 0)}</span><span
                    :if={r.meta != ""}
                    class="mono cm"
                  >{r.meta}</span>
                </span>
              </span>
            </.link>
          </div>
        </div>
        <p :if={@peek.days == []} class="dempty">No chats here yet.</p>
        <p class="dnone">No chats match.</p>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Peek">
      // The search hides the chats whose title doesn't match.
      export default {
        mounted() {
          this.query = ""
          this.el.addEventListener("input", e => {
            if (e.target.id !== "peek-search") return
            this.query = e.target.value.trim().toLowerCase()
            this.filter()
          })
        },
        updated() { this.filter() },
        filter() {
          const q = this.query
          let any = false
          this.el.querySelectorAll(".crow").forEach(row => {
            const hit = !q || row.querySelector(".tt").textContent.toLowerCase().includes(q)
            row.classList.toggle("miss", !hit)
            any = any || hit
          })
          this.el.querySelectorAll(".dday").forEach(day => day.classList.toggle("miss", !day.querySelector(".crow:not(.miss)")))
          this.el.classList.toggle("none", q !== "" && !any)
        }
      }
    </script>
    """
  end

  attr :user, :map, required: true

  @doc """
  The account at the bottom of the drawer: the user, and above it Teams, AI
  login, Logins, the theme and Log out.
  """
  def account_menu(assigns) do
    ~H"""
    <div class="dbot">
      <div
        id="account-pop"
        class="pop acct"
        role="dialog"
        aria-label="Account and settings"
        style="display: none"
        phx-click-away={hide_account()}
      >
        <div class="acct-me">{@user.email}</div>
        <.link navigate={~p"/teams"} class="mi"><span class="flex-1">Teams</span><.icon
          name="hero-chevron-right"
          class="size-3.5 muted"
        /></.link>
        <.link navigate={~p"/ai"} class="mi"><span class="flex-1">AI login</span><.icon
          name="hero-chevron-right"
          class="size-3.5 muted"
        /></.link>
        <.link navigate={~p"/logins"} class="mi"><span class="flex-1">Logins</span><.icon
          name="hero-chevron-right"
          class="size-3.5 muted"
        /></.link>
        <.link navigate={~p"/users/settings"} class="mi"><span class="flex-1">Email and password</span><.icon
          name="hero-chevron-right"
          class="size-3.5 muted"
        /></.link>
        <div class="msep" role="separator"></div>
        <div class="h">Theme</div>
        <.form for={%{}} action={~p"/users/theme"} method="post" class="tseg" aria-label="Theme">
          <button
            :for={{value, label} <- [{"system", "System"}, {"light", "Light"}, {"dark", "Dark"}]}
            name="theme"
            value={value}
            aria-pressed={to_string(@user.theme == value)}
          >
            {label}
          </button>
        </.form>
        <div class="msep" role="separator"></div>
        <.link href={~p"/users/log-out"} method="delete" class="mi">Log out</.link>
      </div>
      <button
        id="account-btn"
        type="button"
        class="mi acct-btn"
        aria-label="Account and settings"
        aria-haspopup="dialog"
        aria-expanded="false"
        phx-click={
          JS.toggle(to: "#account-pop", display: "flex")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
      >
        <span class="acct-av">{initial(@user.email)}</span>
        <span class="flex-1 truncate">{@user.email}</span>
        <.icon name="hero-chevron-up" class="size-3.5 muted" />
      </button>
    </div>
    """
  end

  defp hide_account,
    do:
      JS.hide(to: "#account-pop")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#account-btn")

  @doc """
  The rail on wide screens: All projects, the drawer of chats and projects,
  New chat, and the account.
  """
  attr :new_chat, :any, required: true, doc: "New chat's JS"
  attr :user, :map, required: true, doc: "the signed-in user, for the account button"
  attr :home?, :boolean, default: false, doc: "the projects page is the page"

  def rail(assigns) do
    ~H"""
    <nav class="rail" aria-label="Workspace">
      <.link
        navigate={~p"/projects"}
        class="icon-btn"
        aria-label="All projects"
        aria-current={@home? && "page"}
        title="All projects"
      >
        <Layouts.mark size={28} />
      </.link>
      <button
        type="button"
        class="icon-btn"
        aria-label="Chats and projects"
        title="Chats and projects (⌃B H)"
        phx-click={JS.add_class("show-drawer", to: ".ws-root")}
        data-kb-key="h"
        data-kb-label="Chats and projects"
        data-kb-group="Chats"
      >
        <svg
          width="20"
          height="20"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <rect x="3" y="4" width="18" height="16" rx="3" /><path d="M9 4v16" />
        </svg>
      </button>
      <button
        type="button"
        class="icon-btn"
        aria-label="New chat"
        title="New chat"
        phx-click={@new_chat}
      >
        <.icon name="hero-plus" class="size-5" />
      </button>
      <div class="flex-1"></div>
      <button
        type="button"
        class="icon-btn"
        aria-label="Account and settings"
        title={@user.email}
        phx-click={
          JS.add_class("show-drawer", to: ".ws-root")
          |> JS.remove_class("switching", to: "#drawer")
          |> JS.show(to: "#account-pop", display: "flex")
          |> JS.set_attribute({"aria-expanded", "true"}, to: "#account-btn")
        }
      >
        <span class="rav">{initial(@user.email)}</span>
      </button>
    </nav>
    """
  end

  attr :tab, :map, required: true
  attr :url, :string, required: true
  attr :current, :boolean, required: true
  attr :title, :string, required: true
  attr :status, :any, required: true, doc: "`{text, tone}`, from `row_status/2`"
  attr :meta, :string, required: true
  attr :done, :boolean, default: false
  attr :confirm, :string, default: nil

  # A chat in the drawer: its title over two lines, where its change stands
  # and its number. Its close button shows on hover, or while editing.
  defp chat_row(assigns) do
    ~H"""
    <div id={"chat-#{@tab.chat.id}"} class={["crow", @done && "past"]} data-on={to_string(@current)}>
      <.link
        patch={@url}
        class="crb"
        aria-current={@current && "page"}
        data-kb="item"
        title={Enum.join(Enum.reject([@title, elem(@status, 0), @meta], &(&1 == "")), " · ")}
      >
        <span :if={@done} class="okic" aria-hidden="true">
          <.icon name="hero-check" class="size-[13px]" />
        </span>
        <span :if={!@done} class={["cdot", elem(@status, 1)]} aria-hidden="true"></span>
        <span class="cb">
          <span class="ct"><span class="tt">{@title}</span></span>
          <span class="cs2">
            <span class={["cst", elem(@status, 1)]}>{elem(@status, 0)}</span><span
              :if={@meta != ""}
              class="mono cm"
            >{@meta}</span>
          </span>
        </span>
      </.link>
      <button
        :if={!@done}
        type="button"
        class="cx"
        phx-click="close_chat"
        phx-value-id={@tab.chat.id}
        aria-label={"Close #{@title}"}
        title="Close (⌃B Q)"
        data-confirm={@confirm}
        data-kb-key={if @current, do: "q"}
        data-kb-label="Close this chat"
        data-kb-group="Chats"
      >
        <.icon name="hero-x-mark" class="size-3" />
      </button>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :state, :string, required: true
  attr :pct, :integer, required: true

  @doc "A project's initial, its health bar along the bottom."
  def tile(assigns) do
    ~H"""
    <span class="ri" aria-hidden="true">
      {initial(@name)}<span class={["rhp", @state]}><i style={"width: #{@pct}%"}></i></span>
    </span>
    """
  end

  @doc "Why New chat is off."
  def full_text,
    do:
      "You have #{Chats.max()} chats with open changes. Merge or discard one, then send " <>
        "this again: it stays in the box."

  @doc "The chats that aren't done, the one worked on last first."
  def open_chats(tabs, live_only?), do: Enum.reject(tabs, &Activity.done?(&1, live_only?))

  @days ["Today", "Yesterday", "This week", "Older"]

  @doc """
  The chats by the day they were worked on, each day's last first, and how
  many of each day's are done.
  """
  def by_day(tabs, live_only?) do
    tabs
    |> Enum.group_by(&day/1)
    |> Enum.sort_by(fn {day, _tabs} -> Enum.find_index(@days, &(&1 == day)) end)
    |> Enum.map(fn {day, tabs} ->
      {day, tabs, Enum.count(tabs, &Activity.done?(&1, live_only?))}
    end)
  end

  # When a chat was worked on, in the drawer's words.
  defp day(tab) do
    case Date.diff(Date.utc_today(), DateTime.to_date(tab.worked_at)) do
      n when n <= 0 -> "Today"
      1 -> "Yesterday"
      n when n < 7 -> "This week"
      _ -> "Older"
    end
  end

  @doc "Where a chat's change stands, in a word or two, and its tone."
  def row_status(%{phase: "live"}, true), do: {"Live", "done"}
  def row_status(%{phase: "live"}, false), do: {"On prod", "done"}
  def row_status(%{phase: "landing"}, true), do: {"On main", "done"}
  def row_status(%{phase: "landing"}, false), do: {"On main", "working"}

  def row_status(%{phase: "working", draft: %{status: "checking"}}, _),
    do: {"Checking", "working"}

  def row_status(%{phase: "working"}, _live_only?), do: {"Working", "working"}
  def row_status(%{phase: "staged"}, _live_only?), do: {"On staging · ship", "waiting"}
  def row_status(%{phase: "failed"}, _live_only?), do: {"Checks failed", "err"}
  def row_status(%{phase: "ready"}, _live_only?), do: {"PR open", "waiting"}
  def row_status(%{phase: "merged"}, _live_only?), do: {"PR merged", "done"}
  def row_status(%{phase: "closed"}, _live_only?), do: {"PR closed", "done"}
  def row_status(%{phase: "drawn"}, _live_only?), do: {"Boards on main", "done"}
  def row_status(%{phase: "idle"}, _live_only?), do: {"No change yet", "new"}
  def row_status(_tab, _live_only?), do: {"New chat", "new"}

  @doc "A chat's number once its change is on main, and when it was worked on, if lately."
  def row_meta(tab) do
    recent =
      case DateTime.diff(DateTime.utc_now(), tab.worked_at) do
        s when s < 60 -> "now"
        s when s < 3600 -> "#{div(s, 60)} min ago"
        _ -> nil
      end

    [number(tab) && "##{number(tab)}", recent] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  @doc "A chat's name: its title, or what an empty one is for."
  def chat_title(%{chat: %{title: "", follows: id}}, _project, _nothing_built?) when id != nil,
    do: "Follow-up to ##{id}"

  def chat_title(%{chat: %{title: ""}}, project, true),
    do: "What should #{project && project.name} do?"

  def chat_title(%{chat: %{title: ""}}, _project, _nothing_built?), do: "New chat"
  def chat_title(%{chat: %{title: title}}, _project, _nothing_built?), do: title

  # A chat's change has a number once it is on main.
  defp number(%{draft: %{change: id}}) when id != nil, do: id
  defp number(_tab), do: nil

  # Closing an empty chat loses nothing; any other asks first. What a chat
  # merged stays, and so does a repo chat's pull request.
  defp close_confirm(%{phase: "new"}, _repo?), do: nil

  defp close_confirm(%{phase: phase}, _repo?) when phase in ~w(landing staged drawn),
    do: "Close this chat? What it merged stays; its agent and preview go."

  defp close_confirm(_tab, true),
    do:
      "Close this chat? Its agent, preview and checkout go; a pull request it opened stays open."

  defp close_confirm(%{phase: "failed"}, false),
    do: "Discard this change? The chat closes with it."

  defp close_confirm(_tab, false),
    do: "Close this chat? The conversation goes with it."

  defp initial(name), do: name |> to_string() |> String.first() |> to_string() |> String.upcase()

  ## Chat bar

  attr :title, :string, required: true, doc: "the open chat's"
  attr :project, :map
  attr :ctx, :list, required: true, doc: "the line under the title: project, repo, sharing"
  attr :status, :any, default: nil, doc: "where the chat's change stands: `{text, tone}`"
  attr :meta, :string, required: true, doc: "the project's versions, for the menu"
  attr :overview, :boolean, required: true
  attr :sharing, :map
  attr :live_only?, :boolean, required: true
  attr :repo?, :boolean, required: true
  attr :secrets, :list, required: true
  attr :open_incidents, :integer, required: true
  attr :preview_open, :boolean, required: true, doc: "the preview shows beside the chat"
  attr :preview_tone, :string, required: true, doc: "how the preview is doing: ok, warn, idle…"

  @doc """
  Over the chat, quietly: its title and the line under it, a button that
  opens the project's menu (\"Deploys and usage\", sharing, secrets). A
  closed preview comes back with \"Preview\"; on phones the preview button
  opens it over the chat.
  """
  def chat_bar(assigns) do
    ~H"""
    <header class="pbar">
      <button
        type="button"
        class="icon-btn pbar-menu"
        aria-label="Chats and projects"
        phx-click={JS.add_class("show-drawer", to: ".ws-root")}
      >
        <.icon name="hero-bars-2" class="size-5" />
      </button>
      <div class="menuw pbar-title">
        <button
          id="more-btn"
          type="button"
          class="pbar-ttl"
          aria-label={
            "#{@title}. Menu for #{@project && @project.name}" <>
              if(@open_incidents > 0, do: ", #{@open_incidents} open incidents", else: "")
          }
          aria-haspopup="menu"
          aria-expanded="false"
          phx-click={
            JS.toggle(to: "#more-menu")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
        >
          <span class="pbar-name"><span class="pbar-t">{@title}</span></span>
          <span class="pbar-meta">
            {Enum.join(@ctx, " · ")}<span :if={@status}>{if @ctx != [], do: " · "}<span class={[
              "cst",
              elem(@status, 1)
            ]}>{elem(@status, 0)}</span></span>
          </span>
          <span class="pbar-chev" aria-hidden="true">
            <.icon name="hero-chevron-down" class="size-3.5" />
            <span :if={@open_incidents > 0} class="mdot"></span>
          </span>
        </button>
        <div
          id="more-menu"
          class="menu"
          role="menu"
          style="display: none"
          phx-click-away={hide_menu()}
        >
          <div class="menu-meta mono">{@meta}</div>
          <button
            :if={!@repo?}
            id="overview-btn"
            type="button"
            role="menuitem"
            phx-click={hide_menu() |> JS.push("toggle_overview")}
            data-kb-key="s"
            data-kb-label="Deploys and usage"
            data-kb-group="Ship"
          >
            {if @overview, do: "Back to preview", else: "Deploys and usage"}<span
              :if={@open_incidents > 0}
              class="k text-[var(--err)]"
            >{@open_incidents} {if @open_incidents == 1, do: "incident", else: "incidents"}</span>
          </button>
          <div :if={!@repo?} class="msep" role="separator"></div>
          <button
            :if={@sharing}
            type="button"
            role="menuitem"
            phx-click={hide_menu() |> JS.push("dialog", value: %{dialog: "share"})}
          >
            Share<span class="k">{if @sharing.team, do: @sharing.team.name, else: "Only me"}</span>
          </button>
          <button
            :if={@sharing && @sharing.owner? && @sharing.team && @sharing.teammates != []}
            type="button"
            role="menuitem"
            phx-click={hide_menu() |> JS.push("dialog", value: %{dialog: "hand_over"})}
          >
            Hand over
          </button>
          <button
            type="button"
            role="menuitem"
            phx-click={hide_menu() |> JS.push("dialog", value: %{dialog: "secrets"})}
            data-kb-key="k"
            data-kb-label="Secrets"
            data-kb-group="Ship"
          >
            Secrets<span class={["k", asked(@secrets) != [] && "text-[var(--warn)]"]}>{secrets_text(
              @secrets
            )}</span>
          </button>
          <div :if={add_envs?(assigns)} class="msep" role="separator"></div>
          <button
            :if={add_envs?(assigns)}
            type="button"
            role="menuitem"
            phx-click={hide_menu() |> JS.push("add_envs")}
            data-confirm="Add staging? From then on main goes to staging first, and you ship it to prod. This can't be undone."
          >
            Add staging
          </button>
        </div>
      </div>
      <div class="pbar-acts">
        <button
          :if={!@preview_open}
          id="preview-chip"
          type="button"
          class="chip fill pbar-wide"
          phx-click="toggle_preview"
        >
          <span class={["st", @preview_tone]}><span class="dot"></span></span>Preview
        </button>
        <button
          id="pane-btn"
          type="button"
          class="icon-btn pbar-pane"
          aria-label="Preview the app"
          phx-click="pane"
          phx-value-pane="preview"
        >
          <.icon name="hero-window" class="size-5" />
          <span class={["pdot", @preview_tone]} aria-hidden="true"></span>
        </button>
      </div>
    </header>
    """
  end

  defp add_envs?(assigns),
    do:
      assigns.live_only? and not assigns.repo? and
        (assigns.sharing == nil or assigns.sharing.owner?)

  defp hide_menu,
    do: JS.hide(to: "#more-menu") |> JS.set_attribute({"aria-expanded", "false"}, to: "#more-btn")

  ## Agent

  attr :chat, :map, required: true
  attr :agents, :list, required: true, doc: "the agents the project has (`Burrow.Chats.agents/1`)"

  @doc """
  The chat's opencode agent: Plan reads and plans, Build does the work,
  Design only draws boards. It goes with the chat's next message.
  """
  def agent_pick(assigns) do
    assigns = assign(assigns, :agent, assigns.chat.agent || "build")

    ~H"""
    <div class="apick">
      <.icon name={agent_icon(@agent)} class="size-4 ai" />
      <label class="sr-only" for="agent-pick">Agent</label>
      <select id="agent-pick" name="agent" phx-change="pick_agent" class="field pick">
        <option :for={a <- @agents} value={a} selected={a == @agent}>{agent_label(a)}</option>
      </select>
    </div>
    """
  end

  defp agent_icon("plan"), do: "hero-light-bulb"
  defp agent_icon("design"), do: "hero-swatch"
  defp agent_icon(_build), do: "hero-code-bracket"

  defp agent_label(agent), do: String.capitalize(agent)

  ## Model and thinking level

  attr :chat, :map, required: true
  attr :models, :map, required: true, doc: "provider/model => its thinking levels"
  attr :default, :string, required: true, doc: "the owner's model"

  @doc """
  The chat's model, grouped by provider, and its thinking level (the model's
  opencode variants). They go with the chat's next message.
  """
  def model_pick(assigns) do
    model = assigns.chat.model || assigns.default
    efforts = Map.get(assigns.models, model, []) ++ List.wrap(assigns.chat.effort)

    groups =
      [model | Map.keys(assigns.models)]
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.chunk_by(&provider/1)

    assigns = assign(assigns, model: model, efforts: Enum.uniq(efforts), groups: groups)

    ~H"""
    <label class="sr-only" for="model-pick">Model</label>
    <select id="model-pick" name="model" phx-change="pick_model" class="field pick">
      <optgroup :for={group <- @groups} label={provider_label(provider(hd(group)))}>
        <option :for={m <- group} value={m} selected={m == @model}>
          {m |> String.split("/", parts: 2) |> List.last()}
        </option>
      </optgroup>
    </select>
    <label :if={@efforts != []} class="sr-only" for="effort-pick">Thinking</label>
    <select
      :if={@efforts != []}
      id="effort-pick"
      name="effort"
      phx-change="pick_model"
      class="field pick"
    >
      <option value="" selected={@chat.effort == nil}>thinking: default</option>
      <option :for={e <- @efforts} value={e} selected={e == @chat.effort}>thinking: {e}</option>
    </select>
    """
  end

  defp provider(model), do: model |> String.split("/", parts: 2) |> hd()

  # The two opencode providers share one login but not how they are paid for.
  defp provider_label("opencode"), do: "OpenCode Zen · pay per use"
  defp provider_label("opencode-go"), do: "OpenCode Go · subscription"
  defp provider_label(provider), do: provider

  ## Peon at work

  attr :job, :string, default: nil, doc: "mine, wood, build, test or merge; none naps"
  attr :stage, :integer, default: 0, doc: "how far the build is, 0 to 5"

  @doc """
  The peons' camp while the agent works: the logo on two legs, in pixels.
  What the agent is on is what the whole crew does (`job`): reading mines
  gold, fetching deps chops wood, writing code builds the hut, one step per
  change (`stage`), tests hit the training dummy, and handing the change in
  raises the flag while everyone cheers. Before the first tool they nap.
  Click one for a line; four quick clicks and it gets grumpy.
  """
  def peon_at_work(assigns) do
    ~H"""
    <canvas
      id="peon-scene"
      class="peon-scene"
      phx-hook=".PeonScene"
      phx-update="ignore"
      data-job={@job}
      data-stage={@stage}
      width="400"
      height="68"
      role="img"
      aria-label={"Peons at work: " <> job_name(@job)}
    ></canvas>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PeonScene">
      export default {
        mounted() { this.stop = peonScene(this.el) },
        destroyed() { this.stop() }
      }

      // The job and stage come in as data attributes, which LiveView keeps
      // updating on an ignored element; the scene reads them every few frames.
      // The whole crew works the same job and runs over when it changes, once
      // the new job has held for a moment, so quick tool calls don't make
      // them run back and forth.
      function peonScene(canvas) {
        const W = 200, H = 34, S = 2, GY = H - 3, SETTLE = 90;
        const ctx = canvas.getContext("2d");
        ctx.imageSmoothingEnabled = false;
        const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        let col = {};
        const readCols = () => {
          const cs = getComputedStyle(canvas);
          const v = (n) => cs.getPropertyValue(n).trim();
          col = { rock: v("--border-strong"), rock2: v("--text-3"), raised: v("--raised"), text: v("--text"), rust: v("--rust"), dark: v("--sunken") };
        };
        readCols();
        const G = "#8FBF5A", GD = "#6E9B3D", EYE = "#1C2412", TUSK = "#F7F4EA", GOLD = "#E6B65E", GOLD2 = "#B8862F",
          BARK = "#7A4E2D", BARK2 = "#9A6A40", MUD = "#A07850", LEAF = "#4F7A2E", LEAF2 = "#6E9B3D", STEEL = "#C9CED6",
          SACK = "#C9A46B", SPARK = "#FFF4CC";
        const px = (x, y, w, h, c) => { ctx.fillStyle = c; ctx.fillRect(Math.round(x), Math.round(y), w, h) };
        const DOOR = 14, GPILE = 32, WPILE = 44, TREE = 76, SITE = 104, DUMMY = 176;
        // Where the crew works at each station, facing it; more peons than
        // spots take turns, waiting a step behind.
        const stations = {
          wood: { swing: 22, turn: 4, spots: [{ x: TREE - 9, dir: 1 }, { x: TREE + 11, dir: -1 }] },
          build: { swing: 16, spots: [{ x: SITE - 6, dir: 1 }, { x: SITE + 40, dir: -1 }, { x: SITE + 10, dir: 1 }, { x: SITE + 24, dir: -1 }] },
          test: { swing: 20, turn: 4, spots: [{ x: DUMMY - 9, dir: 1 }, { x: DUMMY + 9, dir: -1 }] }
        };
        const lines = { mine: ["Me dig.", "Gold!"], wood: ["Chop chop.", "Wood!"], build: ["Work, work.", "Me build."], test: ["Hit it!", "Zug zug."] };
        const peons = [24, 60, 150, 188].map((home, i) =>
          ({ i, x: home, home, dir: 1, st: "go", t: 0, wait: 0, carry: null, hidden: false, hop: 0, bubble: null, clicks: [], shake: 0, target: home, spot: null, queue: null }));
        const sim = { job: null, stage: 0, cheer: 0 };
        const sparks = [];
        let crew, want, wantT = 0;
        let gold = 3, wood = 2, frame = 0, raf = 0, wobble = 0, dummyHit = 0, dummyLean = 1, merged = false;

        const readSim = () => {
          const job = canvas.dataset.job || null;
          if (job === "merge") {
            sim.job = null;
            if (!merged) { merged = true; sim.stage = 6; sim.cheer = 140 }
          } else {
            sim.job = job;
            if (!merged) sim.stage = Math.min(5, parseInt(canvas.dataset.stage || "0", 10));
          }
        };
        const setCrew = (job) => {
          crew = job;
          Object.values(stations).forEach((s) => s.spots.forEach((spot) => { spot.owner = null }));
          peons.forEach((p) => {
            if (p.hidden) { p.hidden = false; p.x = DOOR }
            // They set off one after another, not as one blob.
            Object.assign(p, { carry: null, spot: null, queue: null, st: "pause", wait: 1 + p.i * 20, t: 0 });
          });
        };
        readSim();
        setCrew(sim.job);
        want = sim.job;

        const walkTo = (p, x) => { p.target = x; p.st = "walk" };
        const queueAt = (spot) => spot.x - 10 * spot.dir;
        // Hands a spot to the peon waiting for it, else leaves it free.
        const leave = (p) => {
          const spot = p.spot, next = peons.find((q) => q.st === "wait" && q.queue === spot);
          p.spot = null;
          spot.owner = next || null;
          if (next) { next.spot = spot; next.queue = null; walkTo(next, spot.x) }
          return spot;
        };
        const arrive = (p) => {
          if (p.carry) {
            if (p.carry === "gold") gold = gold >= 12 ? 3 : gold + 1; else wood = wood >= 8 ? 2 : wood + 1;
            Object.assign(p, { carry: null, hop: 8, st: "pause", wait: 10 });
          } else if (crew === "mine" && p.x === DOOR) {
            Object.assign(p, { hidden: true, st: "inside", wait: 40 + Math.floor(Math.random() * 40) });
          } else if (p.spot && p.x === p.spot.x) {
            Object.assign(p, { st: "work", t: 0, dir: p.spot.dir });
          } else p.st = "go";
        };
        // What a peon does next, when it is not walking or working.
        const decide = (p) => {
          if (!crew) {
            if (p.x === p.home) { p.st = "sit"; p.dir = 1 } else walkTo(p, p.home);
            return;
          }
          if (crew === "mine") return walkTo(p, DOOR);
          const spots = stations[crew].spots;
          if (p.spot) return walkTo(p, p.spot.x);
          const spot = [spots[p.i % spots.length], ...spots].find((s) => !s.owner);
          if (spot) { spot.owner = p; p.spot = spot; return walkTo(p, spot.x) }
          const queue = spots[p.i % spots.length];
          if (p.x === queueAt(queue)) { p.st = "wait"; p.queue = queue; p.dir = queue.dir }
          else walkTo(p, queueAt(queue));
        };
        const work = (p) => {
          const s = stations[crew], swing = s.swing;
          p.t += 1;
          if (crew === "wood" && p.t % swing === swing / 2) {
            wobble = 8;
            for (let i = 0; i < 2; i++)
              sparks.push({ x: TREE + 1 - 2 * p.dir, y: GY - 6, vx: -p.dir * (0.3 + Math.random() * 0.5), vy: -0.7 - Math.random() * 0.5, life: 36, c: BARK2 });
          }
          if (crew === "build" && p.t % swing === swing / 2)
            for (let i = 0; i < 2; i++)
              sparks.push({ x: p.x + 5 * p.dir, y: GY - 6, vx: Math.random() * 0.6 - 0.3, vy: -0.6 - Math.random() * 0.5, life: 18, c: SPARK });
          if (crew === "test" && p.t % swing === swing / 2) { dummyHit = 6; dummyLean = p.dir }
          if (!s.turn || p.t < swing * s.turn) return;
          // A turn is done: the chopper carries its wood to the pile, the
          // fighter steps back for whoever waits.
          if (crew === "wood") { leave(p); p.carry = "wood"; walkTo(p, WPILE + 2) }
          else if (peons.some((q) => q.st === "wait" && q.queue === p.spot)) {
            const spot = leave(p);
            p.queue = spot;
            walkTo(p, queueAt(spot));
          } else p.t = 0;
        };
        const step = (p) => {
          if (p.st === "walk") {
            const d = p.target - p.x, speed = p.carry ? 0.5 : 1;
            if (Math.abs(d) <= speed) { p.x = p.target; arrive(p); return }
            p.dir = d > 0 ? 1 : -1;
            // Single file behind whoever walks ahead the same way.
            if (peons.some((q) => q !== p && !q.hidden && q.st === "walk" && q.dir === p.dir && (q.x - p.x) * p.dir > 0 && (q.x - p.x) * p.dir < 10)) return;
            p.x += p.dir * speed; p.t += 1;
          } else if (p.st === "inside") {
            if (--p.wait <= 0) { p.hidden = false; p.carry = "gold"; walkTo(p, GPILE + 2) }
          } else if (p.st === "pause") {
            if (--p.wait <= 0) p.st = "go";
          } else if (p.st === "work") work(p);
          else if (p.st !== "wait" || !crew) decide(p);
        };

        const drawZ = (x, y) => { px(x, y, 3, 1, col.rock2); px(x + 1, y + 1, 1, 1, col.rock2); px(x, y + 2, 3, 1, col.rock2) };
        const drawPeon = (p) => {
          if (p.hidden) return;
          const sitting = p.st === "sit" && p.hop <= 0;
          const sx = Math.round(p.x - 4) + (p.shake ? ((frame >> 1) % 2 ? 1 : -1) : 0);
          const lift = p.hop > 0 ? Math.round(Math.sin((p.hop / 10) * Math.PI) * 3) : 0;
          const sy = GY - 9 - lift + (sitting ? 1 : 0);
          // A tool, drawn from the peon's facing side.
          const tool = (dx, y, w, h, c) => px(p.dir > 0 ? sx + dx : sx + 8 - dx - w, sy + y, w, h, c);
          px(sx + 1, sy, 6, 1, G); px(sx, sy + 1, 8, 6, G); px(sx + 1, sy + 7, 6, 1, G); px(sx, sy + 6, 8, 1, GD);
          const o = p.dir > 0 ? 1 : 0;
          const a = sx + 1 + o, b = sx + 5 + o;
          if (sitting) { px(a, sy + 3, 2, 1, EYE); px(b - 1, sy + 3, 2, 1, EYE) }
          else { px(a, sy + 2, 1, 1, EYE); px(b, sy + 2, 1, 1, EYE) }
          px(a, sy + 5, 1, 2, TUSK); px(b, sy + 5, 1, 2, TUSK);
          if (!sitting) {
            const leg = p.st === "walk" && (p.t >> (p.carry ? 3 : 2)) % 2;
            px(sx + (leg ? 1 : 2), sy + 8, 1, 1, EYE); px(sx + (leg ? 6 : 5), sy + 8, 1, 1, EYE);
          }
          const z = (frame + p.home * 7) % 150;
          if (sitting && z < 60) drawZ(sx + 7 + Math.floor(z / 20), sy - 3 - Math.floor(z / 12));
          if (p.carry === "gold") { px(sx + 2, sy - 3, 4, 2, GOLD); px(sx + 3, sy - 4, 2, 1, GOLD2) }
          if (p.carry === "wood") { px(sx - 1, sy - 3, 10, 2, BARK); px(sx + 8, sy - 3, 1, 2, BARK2) }
          if (p.st === "work") {
            const swing = stations[crew].swing, up = p.t % swing < swing / 2;
            if (crew === "wood") {
              if (up) { tool(8, -1, 1, 5, BARK); tool(7, -3, 3, 2, STEEL) }
              else { tool(8, 3, 3, 1, BARK); tool(10, 1, 2, 4, STEEL) }
            } else if (crew === "build") {
              if (up) { tool(8, 1, 1, 3, BARK); tool(7, 0, 3, 1, STEEL) }
              else { tool(8, 3, 3, 1, BARK); tool(10, 2, 1, 3, STEEL) }
            } else if (crew === "test") {
              if (up) { tool(8, -3, 1, 6, STEEL); tool(7, 2, 3, 1, BARK) }
              else { tool(8, 3, 6, 1, STEEL); tool(7, 2, 1, 3, BARK) }
            }
          }
        };
        const drawMine = () => {
          for (let i = 0; i < 14; i++) { const h = Math.round(13 * Math.sin((Math.PI * (i + 0.5)) / 14)); px(i * 2, GY - h, 2, h, col.rock) }
          px(DOOR - 4, GY - 8, 8, 8, col.dark); px(DOOR - 3, GY - 9, 6, 1, col.dark);
          px(DOOR - 5, GY - 9, 1, 9, BARK); px(DOOR + 4, GY - 9, 1, 9, BARK); px(DOOR - 5, GY - 10, 10, 1, BARK2);
          [[5, GY - 4], [21, GY - 5], [9, GY - 9], [18, GY - 11]].forEach(([x, y], k) =>
            px(x, y, 1, 1, crew === "mine" && ((frame >> 3) + k) % 3 === 0 ? SPARK : GOLD));
          for (let i = 0; i < gold; i++) {
            const r = i < 5 ? 0 : i < 9 ? 1 : 2, k = i - [0, 5, 9][r];
            px(GPILE - 2 + r + k * 2, GY - 2 - r * 2, 2, 2, (i + r) % 3 ? GOLD : GOLD2);
          }
        };
        const drawTree = () => {
          const sway = wobble ? (wobble % 4 < 2 ? 1 : -1) : 0;
          px(TREE, GY - 8, 3, 8, BARK);
          for (let r = 0; r < 16; r++) {
            const w = 2 + Math.floor((r % 6) * 1.5) + Math.floor(r / 6) * 2;
            px(TREE + 1 - Math.floor(w / 2) + (r < 8 ? sway : 0), GY - 24 + r, w + 1, 1, r % 6 === 5 ? LEAF2 : LEAF);
          }
          for (let i = 0; i < wood; i++) { const r = Math.floor(i / 3); px(WPILE - 2 + (i % 3) * 2 + r, GY - 2 - r * 2, 6, 2, i % 2 ? BARK : BARK2) }
        };
        // The hut, one step per change; the flag goes up when it is handed in.
        const drawSite = () => {
          const st = sim.stage, x0 = SITE, w = 34;
          if (st < 1) { px(x0, GY - 3, 1, 3, BARK); px(x0 + w - 1, GY - 3, 1, 3, BARK); px(x0, GY - 3, w, 1, BARK2); return }
          px(x0, GY - 2, w, 2, col.rock);
          if (st >= 2) px(x0 + 2, GY - 7, w - 4, 5, MUD);
          if (st >= 3) { px(x0 + 2, GY - 12, w - 4, 5, MUD); px(x0 + 3, GY - 9, w - 6, 1, BARK2) }
          if (st >= 2) px(x0 + 14, GY - 9, 6, st >= 3 ? 7 : 4, col.dark);
          if (st >= 4) for (let i = 0; i <= 8; i++) { px(x0 + 1 + i * 2, GY - 13 - i, 2, 1, BARK); px(x0 + w - 3 - i * 2, GY - 13 - i, 2, 1, BARK) }
          if (st >= 5) for (let r = 0; r < 8; r++) { const ww = w - 4 - r * 4; if (ww > 0) px(x0 + 2 + r * 2, GY - 13 - r, ww, 1, r % 2 ? BARK2 : BARK) }
          if (st <= 4) {
            const top = GY - [0, 6, 9, 14, 20][st];
            px(x0 - 2, top, 1, GY - top, BARK); px(x0 + w + 1, top, 1, GY - top, BARK); px(x0 - 2, top + 2, w + 4, 1, BARK2);
          }
          if (st >= 6) {
            const f = (frame >> 4) % 2;
            px(x0 + w / 2, GY - 29, 1, 8, BARK); px(x0 + w / 2 + 1, GY - 29, 5, 3, col.rust); px(x0 + w / 2 + 6, GY - 28 + f, 1, 2, col.rust);
          }
        };
        const drawDummy = () => {
          const lean = dummyHit > 0 ? dummyLean : 0;
          px(DUMMY, GY - 10, 1, 10, BARK);
          px(DUMMY - 3 + lean, GY - 8, 7, 1, BARK2);
          px(DUMMY - 1 + lean, GY - 13, 3, 3, SACK);
        };
        const drawBubble = (p) => {
          if (!p.bubble || p.hidden) return;
          ctx.font = "600 7px Rubik, system-ui, sans-serif";
          const w = Math.ceil(ctx.measureText(p.bubble.text).width) + 6;
          const bx = Math.max(1, Math.min(W - w - 1, Math.round(p.x - w / 2)));
          px(bx, 0, w, 10, col.rock); px(bx + 1, 1, w - 2, 8, col.raised);
          ctx.fillStyle = col.text;
          ctx.fillText(p.bubble.text, bx + 3, 7.5);
        };
        const draw = () => {
          ctx.setTransform(S, 0, 0, S, 0, 0);
          ctx.clearRect(0, 0, W, H);
          px(0, GY, W, 1, col.rock);
          drawMine(); drawTree(); drawSite(); drawDummy();
          sparks.forEach((c) => px(c.x, c.y, 1, 1, c.c));
          peons.forEach(drawPeon);
          peons.forEach(drawBubble);
        };
        const tick = () => {
          frame += 1;
          if (frame % 120 === 0) readCols();
          if (frame % 10 === 0) readSim();
          if (sim.job !== want) { want = sim.job; wantT = 0 } else wantT += 1;
          if (want !== crew && wantT >= SETTLE) setCrew(want);
          if (sim.cheer > 0) { sim.cheer -= 1; peons.forEach((p) => { if (p.hop <= 0 && (frame + p.home) % 24 === 0) p.hop = 10 }) }
          peons.forEach((p) => {
            if (p.bubble && --p.bubble.t <= 0) p.bubble = null;
            if (p.shake) p.shake -= 1;
            if (p.hop) p.hop -= 1;
            step(p);
          });
          if (wobble) wobble -= 1;
          if (dummyHit) dummyHit -= 1;
          for (let i = sparks.length - 1; i >= 0; i--) {
            const c = sparks[i];
            c.x += c.vx; c.y += c.vy; c.vy += 0.08; c.life -= 1;
            if (c.y > GY - 1) { c.y = GY - 1; c.vx *= 0.5 }
            if (c.life <= 0) sparks.splice(i, 1);
          }
          draw();
          raf = requestAnimationFrame(tick);
        };
        const toLogical = (e) => {
          const r = canvas.getBoundingClientRect();
          return [((e.clientX - r.left) / r.width) * W, ((e.clientY - r.top) / r.height) * H];
        };
        const hit = (lx, ly) => peons.find((p) => !p.hidden && lx >= p.x - 6 && lx <= p.x + 6 && ly >= GY - 15 && ly <= GY + 2);
        const onClick = (e) => {
          const p = hit(...toLogical(e));
          if (!p || p.shake > 0) return;
          const now = Date.now();
          p.clicks = p.clicks.filter((t) => now - t < 2500).concat(now);
          if (p.clicks.length >= 4) { p.bubble = { text: "Me busy!", t: 110 }; p.shake = 26; p.clicks = [] }
          else {
            const ls = !crew || p.st === "sit" ? ["Zzz…", "Me rest."] : lines[crew];
            p.bubble = { text: ls[Math.floor(Math.random() * ls.length)], t: 90 }; p.hop = 10;
          }
          if (reduce) draw();
        };
        const onMove = (e) => { canvas.style.cursor = hit(...toLogical(e)) ? "pointer" : "default" };
        canvas.addEventListener("click", onClick);
        canvas.addEventListener("mousemove", onMove);
        if (reduce) {
          draw();
          const redraw = setInterval(() => { readSim(); draw() }, 1000);
          return () => clearInterval(redraw);
        }
        raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
      }
    </script>
    """
  end

  defp job_name("mine"), do: "mining gold"
  defp job_name("wood"), do: "chopping wood"
  defp job_name("build"), do: "building"
  defp job_name("test"), do: "at the training dummy"
  defp job_name("merge"), do: "cheering"
  defp job_name(_), do: "napping"

  ## Change card

  attr :draft, :map, required: true
  attr :tab, :map
  attr :step, :any
  attr :live_only?, :boolean, required: true
  attr :promote, :any
  attr :main_check, :any

  @doc "The chat's change: its checks, how far it got, and shipping it."
  def change_card(assigns) do
    draft = assigns.draft
    phase = (assigns.tab && assigns.tab.phase) || "idle"
    check = assigns.main_check

    # Once on main, main's own check is the last step.
    main =
      if draft.change && check && check.change_id >= draft.change,
        do: [
          %{
            "name" => "main",
            "status" => if(check.status == "running", do: "running", else: check.status)
          }
        ],
        else: []

    assigns =
      assign(assigns,
        phase: phase,
        steps: (draft.checks["steps"] || []) ++ main,
        end_name: env_label("prod", assigns.live_only?),
        reached: reached(phase),
        title: if(draft.change, do: "Change ##{draft.change}", else: "Change")
      )

    ~H"""
    <section class="framed ws-cs" aria-label={@title}>
      <div class="csrow">
        <span class="text-[var(--rust)] flex"><.icon
          name="hero-arrows-right-left"
          class="size-[17px]"
        /></span>
        <h2 class="m-0 text-[15px] leading-[22px] font-semibold">{@title}</h2>
        <span class={["st", badge_tone(@phase)]}><span class="dot"></span>{badge(@phase, @live_only?)}</span>
        <div class="flow mono ml-auto">
          <span class="on">dev</span>
          <.icon name="hero-arrow-right" class="size-3" />
          <span class={@reached >= 1 && "on"}>main</span>
          <span :if={!@live_only?} class="contents">
            <.icon name="hero-arrow-right" class="size-3" />
            <span class={@reached >= 2 && "on"}>staging</span>
          </span>
          <.icon name="hero-arrow-right" class="size-3" />
          <span class={@reached >= 3 && "on"}>{@end_name}</span>
        </div>
      </div>
      <div class="truncate muted text-[13px]">{@draft.intent}</div>
      <div class="csrow">
        <div class="steps">
          <span :for={step <- @steps} class={["step", step_kind(step["status"])]}>
            <span class="i"><.step_icon status={step["status"]} /></span>
            <span class="mono">{step["name"]}</span>
          </span>
          <span :if={@draft.status == "checking"} class="step run">
            <span class="i"><.step_icon status="running" /></span>
            <span class="mono">{step_text(@step)}</span>
          </span>
        </div>
        <div class="acts">
          <button
            :if={@phase == "failed" and @tab}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="close_chat"
            phx-value-id={@tab.chat.id}
            data-confirm="Discard this change? The chat closes with it."
          >
            Discard
          </button>
          <div :if={@phase in ~w(landing staged)} class="dep" role="status">
            <span :if={@phase == "staged"} class="live"><.icon name="hero-check" class="size-4" />
            On staging</span>
            <span :if={@phase == "landing" and !@promote}>On main</span>
            <span :if={@phase == "landing" and !@promote} class="dbar" aria-hidden="true"><i></i></span>
            <button
              :if={@phase == "staged"}
              type="button"
              class="btn btn-secondary btn-sm"
              phx-click="view"
              phx-value-view="staging"
            >
              View
            </button>
            <button
              :if={@promote}
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="ship"
              phx-value-id={@promote}
              data-kb-key="a"
              data-kb-label="Ship"
              data-kb-group="Ship"
              data-confirm={"Ship ##{@promote} to #{@end_name}?"}
            >
              Ship
            </button>
          </div>
          <span :if={@phase == "live"} class="live" role="status">
            <.icon name="hero-check" class="size-4" /> {if @live_only?,
              do: "Live",
              else: "Live on prod"}
          </span>
        </div>
      </div>
    </section>
    """
  end

  attr :tickets, :list, required: true, doc: "the chat's queue (Burrow.Tickets)"
  attr :busy?, :boolean, required: true

  @doc """
  The chat's queue, over the box (a sheet on phones), opened from the line
  under the camp: the ticket in progress, the ones up next in order, a box
  to add one, and the done ones folded away. Tickets that haven't started
  can be deleted; the agent takes the rest one by one.
  """
  def queue_card(assigns) do
    {closed, open} = Enum.split_with(assigns.tickets, &(&1.status == "closed"))
    {now, next} = Enum.split_with(open, &(&1.status == "in_progress"))
    assigns = assign(assigns, now: now, next: next, closed: closed)

    ~H"""
    <div id="queue" class="qpop-w">
      <div id="queue-pop" class="pop qpop" role="dialog" aria-label="Queue" style="display: none">
        <button
          type="button"
          class="qscrim"
          aria-label="Close the queue"
          phx-click={hide_queue()}
        ></button>
        <div class="qsheet" phx-click-away={hide_queue()}>
          <div class="qtop">
            <span class="qtitle">Queue</span>
            <span class="muted text-[13px]">{queue_count(@now ++ @next, @closed)}</span>
            <button
              type="button"
              class="icon-btn ml-auto"
              aria-label="Close the queue"
              phx-click={hide_queue()}
            >
              <.icon name="hero-x-mark" class="size-[18px]" />
            </button>
          </div>
          <div :if={@now != []} class="h">Now</div>
          <div :for={t <- @now} id={"ticket-#{t.id}"} class="qrow in_progress">
            <span class="cdot working" aria-hidden="true"></span>
            <span class="qt">{t.title}</span>
            <span class="mono qid">{t.id}</span>
          </div>
          <div class="h">Up next</div>
          <p :if={@next == []} class="qnone">Nothing waiting.</p>
          <div :for={{t, i} <- Enum.with_index(@next, 1)} id={"ticket-#{t.id}"} class="qrow open">
            <span class="mono qn">{i}</span>
            <span class="qt">{t.title}</span>
            <span class="mono qid">{t.id}</span>
            <button
              type="button"
              class="cx"
              phx-click="delete_ticket"
              phx-value-id={t.id}
              aria-label={"Delete \"#{t.title}\" from the queue"}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
          <form id={"queue-add-#{length(@tickets)}"} class="qadd" phx-submit="add_ticket">
            <label class="sr-only" for="queue-add">Add a task to the queue</label>
            <input
              id="queue-add"
              name="text"
              type="text"
              autocomplete="off"
              placeholder="Add a task for after this one…"
            />
            <button class="icon-btn" aria-label="Add to the queue">
              <.icon name="hero-plus" class="size-5" />
            </button>
          </form>
          <p class="qhelp">Peon takes these in order when the current task is done.</p>
          <button
            :if={!@busy? && @next != []}
            id="work-queue"
            type="button"
            class="btn btn-secondary btn-sm self-start"
            phx-click={hide_queue() |> JS.push("work_queue")}
          >
            Work the queue
          </button>
          <details
            :if={@closed != []}
            id="queue-done"
            class="qdone"
            phx-mounted={JS.ignore_attributes(["open"])}
          >
            <summary class="qmore">
              <.icon name="hero-check" class="size-3.5 text-[var(--ok)]" />
              <span>{length(@closed)} done</span>
              <.icon name="hero-chevron-right" class="size-3.5 chev" />
            </summary>
            <div :for={t <- @closed} id={"ticket-#{t.id}"} class="qrow closed">
              <span class="qt">{t.title}</span>
              <span class="mono qid">{t.id}</span>
            </div>
          </details>
        </div>
      </div>
    </div>
    """
  end

  defp hide_queue,
    do:
      JS.hide(to: "#queue-pop")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#queue-link")

  @doc "The queue's line under the camp: \"2 next\", \"nothing next\"."
  def queue_next(tickets) do
    case Enum.count(tickets, &(&1.status == "open")) do
      0 -> "nothing next"
      n -> "#{n} next"
    end
  end

  defp queue_count([], closed), do: "all #{length(closed)} done"
  defp queue_count(open, []), do: "#{length(open)} to do"
  defp queue_count(open, closed), do: "#{length(open)} to do · #{length(closed)} done"

  attr :tab, :map, required: true, doc: "a done chat's tab (`Burrow.Activity.done?/2`)"
  attr :attach?, :boolean, required: true, doc: "its agent runs, so opencode can attach"

  @doc """
  In place of a done chat's box: its change is out and the chat stays in
  the drawer, so the next change starts in a new chat, maybe following up
  on this one.
  """
  def chat_done(assigns) do
    assigns = assign(assigns, id: assigns.tab.draft.change)

    ~H"""
    <section id="chat-done" class="ws-done" aria-label="This chat is done">
      <div class="h">
        <.icon name="hero-check" class="size-[17px] self-center text-[var(--ok)]" />
        <b>#{@id} {if @tab.phase == "live", do: "is live.", else: "is on main."}</b>
        <span>This chat is done.</span>
      </div>
      <div class="a">
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="new_chat"
        >
          New chat <kbd>⌃B C</kbd>
        </button>
        <button
          type="button"
          class="btn btn-secondary btn-sm"
          phx-click="follow_up"
        >
          Follow up on #{@id}
        </button>
        <button :if={@attach?} type="button" class="xlink mono ml-auto" phx-click="toggle_attach">
          Open in opencode
        </button>
      </div>
    </section>
    """
  end

  defp reached("landing"), do: 1
  defp reached("staged"), do: 2
  defp reached("live"), do: 3
  defp reached(_phase), do: 0

  defp badge("working", _), do: "checking"
  defp badge("failed", _), do: "checks failed"
  defp badge("ready", _), do: "pull request open"
  defp badge("merged", _), do: "pull request merged"
  defp badge("closed", _), do: "pull request closed"
  defp badge("landing", true), do: "on main"
  defp badge("landing", false), do: "on main"
  defp badge("staged", _), do: "on staging"
  defp badge("live", true), do: "live"
  defp badge("live", false), do: "on prod"
  defp badge(_, _), do: "not submitted"

  defp badge_tone(phase) when phase in ~w(working landing), do: "warn"
  defp badge_tone("failed"), do: "err"
  defp badge_tone(phase) when phase in ~w(ready merged staged live), do: "ok"
  defp badge_tone(_), do: "idle"

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
  defp step_kind("running"), do: "run"
  defp step_kind(_), do: "wait"

  defp step_text({step, status}), do: "#{step} #{status}"
  defp step_text(_), do: "checking…"

  ## Preview

  attr :preview, :map, required: true
  attr :view, :string, required: true
  attr :env_names, :list, required: true
  attr :envs, :map, required: true, doc: "each environment's `Burrow.Env.info/2`"
  attr :live_only?, :boolean, required: true
  attr :dev?, :boolean, required: true
  attr :number, :any, doc: "the chat's change number, once on main"
  attr :chat, :map
  attr :info, :map
  attr :frame_key, :integer, required: true
  attr :phone, :boolean, default: false, doc: "shows the app phone-sized, on wide screens"
  attr :show_logs, :boolean, required: true
  attr :logs, :string, required: true
  attr :project, :map
  attr :design, :map, default: nil, doc: "the design view's switch: `%{count, drawing, note}`"
  attr :now, :string, default: nil, doc: "what Peon is on, for the phone's line back to the chat"
  slot :inner_block, doc: "the design view"

  @doc """
  The version picker and what it shows: the chat's dev preview, staging or
  prod, or its boards (the inner block) in the design view. Beside it the
  address, \"Open\" (the app, its other ports, the pull request), reload,
  the app as a phone (wide screens only), and a ⋯ menu with the logs, a
  restart and how long the preview stays up.
  """
  def preview_pane(assigns) do
    assigns =
      assign(assigns,
        tone: view_tone(assigns),
        server?:
          (assigns.preview.url != nil and !assigns.preview[:empty]) or
            (assigns.view == "dev" and assigns.info != nil) or assigns.preview[:pr] != nil
      )

    ~H"""
    <div class="vbar">
      <button
        type="button"
        class="icon-btn vback"
        aria-label="Back to the chat"
        phx-click="pane"
        phx-value-pane="chat"
      >
        <.icon name="hero-chevron-left" class="size-5" />
      </button>
      <div class="menuw">
        <button
          id="view-btn"
          type="button"
          class="chip fill vpick"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-label={"Showing #{view_name(@view, @live_only?, @number)}. Change"}
          phx-click={
            JS.toggle(to: "#view-menu") |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
          data-kb-key="e"
          data-kb-label="Version shown"
          data-kb-group="Agent & preview"
        >
          <span class={["st", @tone]}><span class="dot"></span></span>
          <span class="mono">{view_name(@view, @live_only?, @number)}</span>
          <span :if={@design && @design.drawing && @view != "design"} class="ddot" aria-hidden="true"></span>
          <.icon name="hero-chevron-down" class="size-3.5 muted" />
        </button>
        <div
          id="view-menu"
          class="menu vmenu"
          role="menu"
          style="display: none"
          phx-click-away={hide_view_menu()}
        >
          <button
            :for={env <- Enum.reverse(@env_names)}
            type="button"
            role="menuitemradio"
            aria-checked={to_string(@view == env)}
            phx-click={hide_view_menu() |> JS.push("view", value: %{view: env})}
          >
            <span class={["st", st_tone(@envs[env] && @envs[env].status)]}><span class="dot"></span></span>
            <span class="vt">
              <span class="mono">{env_label(env, @live_only?)}</span>
              <span class="vd">{env_about(env, @live_only?)}{env_word(@envs[env])
              |> then(&if(&1 != "", do: " · " <> &1, else: ""))}</span>
            </span>
            <.icon :if={@view == env} name="hero-check" class="size-4 vcheck" />
          </button>
          <button
            type="button"
            role="menuitemradio"
            aria-checked={to_string(@view == "dev")}
            disabled={!@dev?}
            title={
              if !@dev?,
                do:
                  "The chat's dev preview starts with its first message, and goes once its change is live"
            }
            phx-click={hide_view_menu() |> JS.push("view", value: %{view: "dev"})}
          >
            <span class={["st", st_tone(@info && @info.preview_status)]}><span class="dot"></span></span>
            <span class="vt">
              <span class="mono">{if @number && @dev?, do: "dev ##{@number}", else: "dev"}</span>
              <span class="vd">This chat's changes{if @info,
                do: " · " <> preview_word(@info.preview_status)}</span>
            </span>
            <.icon :if={@view == "dev"} name="hero-check" class="size-4 vcheck" />
          </button>
          <button
            :if={@design}
            id="design-view"
            type="button"
            role="menuitemradio"
            aria-checked={to_string(@view == "design")}
            phx-click={hide_view_menu() |> JS.push("view", value: %{view: "design"})}
            data-kb-key="d"
            data-kb-label="Design"
            data-kb-group="Agent & preview"
          >
            <span class={["st", if(@design.drawing, do: "warn", else: "idle")]}><span class="dot"></span></span>
            <span class="vt">
              <span class="mono">design</span>
              <span class="vd">Boards in design/{case design_word(@design) do
                "" -> ""
                word -> " · " <> word
              end}</span>
            </span>
            <.icon :if={@view == "design"} name="hero-check" class="size-4 vcheck" />
          </button>
        </div>
      </div>
      <span :if={@view == "design"} class="vnote">{@design.note}</span>
      <div :if={@view != "design"} class="ws-url mono">
        <.icon name="hero-lock-closed" class="size-3.5 shrink-0 muted" />
        <span class="truncate">{@preview.url || "no preview yet"}</span>
      </div>
      <a
        :if={@view != "design" && @preview.url && !@preview[:empty]}
        href={@preview.url}
        target="_blank"
        rel="noopener"
        class="icon-btn"
        aria-label={"Open #{view_name(@view, @live_only?, @number)} in a new tab"}
        title={"Open #{view_name(@view, @live_only?, @number)} in a new tab"}
      >
        <.icon name="hero-arrow-top-right-on-square" class="size-4" />
      </a>
      <button
        :if={@view != "design" && @preview.url && !@preview[:empty]}
        type="button"
        phx-click="reload_preview"
        data-kb-key="r"
        data-kb-label="Reload preview"
        data-kb-group="Agent & preview"
        class="icon-btn vreload"
        aria-label="Reload preview"
      >
        <.icon name="hero-arrow-path" class="size-[17px]" />
      </button>
      <button
        :if={@view != "design"}
        id="phone-btn"
        type="button"
        phx-click="toggle_phone"
        class="icon-btn vphone"
        aria-pressed={to_string(@phone)}
        aria-label={if @phone, do: "Show full width", else: "Show as phone"}
        title={if @phone, do: "Show full width", else: "Show as phone"}
      >
        <.icon name="hero-device-phone-mobile" class="size-[18px]" />
      </button>
      <div :if={@view != "design" && @server?} class="menuw">
        <button
          id="server-btn"
          type="button"
          class="icon-btn"
          aria-label="Server: other ports, logs, restart"
          aria-haspopup="menu"
          aria-expanded="false"
          phx-click={
            JS.toggle(to: "#server-menu")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
        >
          <.icon name="hero-ellipsis-horizontal" class="size-5" />
        </button>
        <div
          id="server-menu"
          class="menu"
          role="menu"
          style="display: none"
          phx-click-away={hide_server_menu()}
        >
          <a
            :for={{name, url} <- @preview[:links] || []}
            href={url}
            target="_blank"
            rel="noopener"
            role="menuitem"
            phx-click={hide_server_menu()}
          >
            <span class="flex-1 mono">{name}</span><span class="k">↗</span>
          </a>
          <a
            :if={@preview[:pr]}
            href={@preview.pr}
            target="_blank"
            rel="noopener"
            role="menuitem"
            phx-click={hide_server_menu()}
          >
            <span class="flex-1">PR {pr_number(@preview.pr)} on GitHub</span><span class="k">↗</span>
          </a>
          <div :if={(@preview[:links] || []) != [] or @preview[:pr]} class="msep" role="separator">
          </div>
          <button
            :if={@preview.url && !@preview[:empty]}
            type="button"
            role="menuitem"
            phx-click={hide_server_menu() |> JS.push("toggle_logs")}
            data-kb-key="v"
            data-kb-label="Preview logs"
            data-kb-group="Agent & preview"
          >
            {if @show_logs, do: "Hide logs", else: "Logs"}
          </button>
          <button
            :if={@view == "dev" and @info}
            type="button"
            role="menuitem"
            phx-click={hide_server_menu() |> JS.push("restart_preview")}
            data-kb-key="R"
            data-kb-label="Restart preview"
            data-kb-group="Agent & preview"
          >
            Restart the preview
          </button>
          <form
            :if={(@view == "dev" and @chat) && @info}
            id="keep-running-form"
            phx-change="keep_running"
            class="mrow"
          >
            <label for="keep-running">Keeps running</label>
            <select
              id="keep-running"
              name="hours"
              class="field keep"
              title="How long the agent and preview stay up without use, e.g. while others test the preview"
            >
              <option :if={Chats.kept_running?(@chat)} value="kept" selected>
                until {Calendar.strftime(@chat.keep_until, "%b %-d, %H:%M UTC")}
              </option>
              <option value="">30 min idle</option>
              <option value="4">4 hours</option>
              <option value="24">1 day</option>
              <option value="168">7 days</option>
            </select>
          </form>
        </div>
      </div>
      <button
        type="button"
        class="icon-btn vclose"
        aria-label="Put the preview away"
        title="Put the preview away"
        phx-click="toggle_preview"
      >
        <.icon name="hero-x-mark" class="size-[18px]" />
      </button>
    </div>

    {if @view == "design", do: render_slot(@inner_block)}
    <div :if={@view != "design"} class={["ws-prev-body", @phone && "phone"]}>
      <iframe
        :if={@preview.live?}
        id={"preview-#{@view}-#{@frame_key}"}
        src={@preview.url}
        class="ws-frame"
      />
      <div :if={!@preview.live?} class="ws-prev-empty" role="status">
        <.icon
          :if={@preview.status in [:starting, :booting, :loading, :watching]}
          name="hero-arrow-path"
          class="size-8 spin text-[var(--accent-text)]"
        />
        <span :if={@preview[:down]} class="st err text-sm"><span class="dot"></span>{@preview.message}</span>
        <div :if={!@preview[:down]} class="ws-prev-title">{@preview.message}</div>
        <div :if={@preview[:empty] && @preview.url} class="mono muted text-[12.5px]">
          {@preview.url}
        </div>
        <button
          :if={@preview[:down]}
          type="button"
          phx-click="restart_env"
          phx-value-env={@preview.down}
          class="btn btn-secondary btn-sm"
        >
          Restart {env_label(@preview.down, @live_only?)}
        </button>
        <button
          :if={@preview[:wake]}
          type="button"
          phx-click="wake"
          data-kb="row"
          class="btn btn-primary"
        >
          Start again
        </button>
        <a
          :if={@preview[:open] && @preview.url}
          href={@preview.url}
          target="_blank"
          rel="noopener"
          data-kb="row"
          class="btn btn-primary"
        >
          Open {view_name(@view, @live_only?, @number)} in a new tab
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </a>
      </div>
      <section :if={@show_logs} class="ws-logs" aria-label="Logs">
        <div class="ws-logs-head">
          <.icon name="hero-command-line" class="size-4 muted" />
          <span class="font-semibold text-[13px]">Logs</span>
          <span class="mono muted text-xs">{@project && @project.slug} · {view_name(
            @view,
            @live_only?,
            @number
          )}</span>
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
    <button type="button" class="vchat" phx-click="pane" phx-value-pane="chat">
      <span :if={@now} class="swing" aria-hidden="true"><.icon name="hero-wrench" class="size-4" /></span>
      <span class="flex-1 truncate text-left">
        <span :if={@now} class="font-medium text-[var(--text)]">{@now}</span>
      </span>
      <span class="flex items-center gap-0.5 muted">Chat
      <.icon name="hero-chevron-right" class="size-3.5" /></span>
    </button>
    """
  end

  # The picker's dot: how what it shows is doing.
  defp view_tone(%{view: "design", design: %{drawing: true}}), do: "warn"
  defp view_tone(%{view: "design"}), do: "idle"
  defp view_tone(%{preview: preview}), do: st_tone(preview.status)

  defp env_about("prod", _live_only?), do: "What your users see now"
  defp env_about("staging", _live_only?), do: "Main, before it ships"
  defp env_about(_env, _live_only?), do: ""

  defp env_word(nil), do: ""
  defp env_word(%{deployed: nil}), do: "not built"
  defp env_word(%{deployed: id, status: {:crashed, _}}), do: "##{id} · down"
  defp env_word(%{deployed: id}), do: "##{id}"

  defp design_word(%{drawing: true}), do: "drawing"
  defp design_word(%{count: 0}), do: ""
  defp design_word(%{count: count}), do: "#{count} changed"

  defp hide_view_menu, do: hide_pop("#view-menu", "#view-btn")
  defp hide_server_menu, do: hide_pop("#server-menu", "#server-btn")

  defp hide_pop(menu, button),
    do: JS.hide(to: menu) |> JS.set_attribute({"aria-expanded", "false"}, to: button)

  defp view_name("dev", _live_only?, id) when is_integer(id), do: "dev ##{id}"
  defp view_name("dev", _live_only?, _cs), do: "dev"
  defp view_name(env, live_only?, _cs), do: env_label(env, live_only?)

  defp pr_number(url), do: "#" <> (url |> String.split("/") |> List.last())

  @doc "What the project calls an environment: prod is \"live\" when there is no staging."
  def env_label("prod", true), do: "live"
  def env_label(env, _live_only?), do: env

  ## Deploys and usage

  attr :envs, :map, required: true
  attr :env_names, :list, required: true
  attr :live_only?, :boolean, required: true
  attr :tabs, :list, required: true
  attr :info, :map
  attr :promote, :any
  attr :auto_promote, :boolean, required: true
  attr :incidents, :list, required: true
  attr :base, :string, required: true, doc: "the workspace's path"
  attr :deploys, :list, required: true

  @doc """
  In place of the preview: each environment's version, prod's (live's) usage
  and incidents, and the latest deploys.
  """
  def overview(assigns) do
    prod = assigns.envs["prod"]

    assigns =
      assign(assigns,
        prod: prod,
        prod_name: env_label("prod", assigns.live_only?),
        open: Enum.count(assigns.tabs, &(&1.phase in ~w(idle working failed))),
        running?: match?(%{status: :running, deployed: id} when id != nil, prod),
        usage: prod && prod[:usage],
        stats: prod && prod.stats,
        open_incidents: Enum.filter(assigns.incidents, &(&1.status != "resolved"))
      )

    ~H"""
    <div id="overview" class="ov">
      <div class="ov-in">
        <div class="flex items-center justify-between gap-3">
          <h2 class="m-0 text-lg font-semibold">Deploys and usage</h2>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="toggle_overview">
            Back to preview
          </button>
        </div>

        <div>
          <div class="envs">
            <div class="env">
              <div class="flex items-center gap-2.5">
                <span class="eyebrow">dev</span>
                <span :if={@open > 0} class="st ok"><span class="dot"></span>open</span>
              </div>
              <div class="tip">
                {if @open == 0, do: "—", else: @open}<small>{if @open == 0,
                  do: "nothing open",
                  else: "chats at work"}</small>
              </div>
              <a
                :if={@info && @info.preview_url}
                class="xlink"
                href={@info.preview_url}
                target="_blank"
                rel="noopener"
              >
                {host(@info.preview_url)}<.icon name="hero-arrow-top-right-on-square" class="size-3" />
              </a>
            </div>
            <.env_cell
              :for={name <- @env_names}
              name={name}
              info={@envs[name]}
              live_only?={@live_only?}
              envs={@envs}
            />
          </div>
          <div class="sync">
            <span>{sync_text(assigns)}</span>
            <button
              :if={@promote}
              type="button"
              class="btn btn-secondary btn-sm"
              phx-click="ship"
              phx-value-id={@promote}
              data-kb-key="P"
              data-kb-label="Ship"
              data-kb-group="Ship"
              data-confirm={"Ship ##{@promote} to #{@prod_name}?"}
            >
              Ship
            </button>
            <label class="check ml-auto">
              <input
                id="auto-ship"
                type="checkbox"
                data-kb="row"
                checked={@auto_promote}
                phx-click="toggle_auto_ship"
              /> ship automatically
            </label>
          </div>
        </div>

        <div>
          <div class="sec-h">
            <span class="eyebrow">{@prod_name} · {uptime(@prod, @stats)}</span>
          </div>
          <div :if={@running? and @usage} class="stats">
            <.stat
              label="Live sessions"
              value={@usage.sessions}
              points={Enum.map(@usage.history, & &1.sessions)}
            />
            <.stat
              label="Requests / min"
              value={@usage.rpm}
              points={Enum.map(@usage.history, & &1.rpm)}
            />
            <.stat
              label="p95 response"
              value={@usage.p95 || 0}
              unit="ms"
              points={Enum.map(@usage.history, & &1.p95)}
            />
            <div class="stat">
              <span class="l">Users today</span><span class="v">{@usage.visitors}</span>
            </div>
            <div class="stat">
              <span class="l">Memory</span>
              <span class="v">{mb(@stats && @stats["total"])}<span class="u">MB of {Burrow.Sandbox.memory_mb()}</span></span>
              <span
                class="meter"
                role="img"
                aria-label={"#{mb(@stats && @stats["total"])} of #{Burrow.Sandbox.memory_mb()} megabytes used"}
              >
                <i style={"width: #{memory_pct(@stats)}%"}></i>
              </span>
            </div>
            <div class="stat">
              <span class="l">Errors, last hour</span>
              <span class={["v", @usage.errors > 0 && "text-[var(--err)]"]}>{@usage.errors}</span>
            </div>
          </div>
          <div :if={!@running?} class="down-row">
            <%= if @prod && @prod.deployed do %>
              <span class={["st", if(match?({:crashed, _}, @prod.status), do: "err", else: "warn")]}>
                <span class="dot"></span>{down_text(@prod, @prod_name)}
              </span>
              <button
                :if={match?({:crashed, _}, @prod.status)}
                type="button"
                class="btn btn-secondary btn-sm"
                phx-click="restart_env"
                phx-value-env="prod"
              >
                Restart {@prod_name}
              </button>
            <% else %>
              <span class="st idle"><span class="dot"></span>Nothing built yet</span>
            <% end %>
          </div>
          <ul :if={@open_incidents != []} class="rows mt-4" aria-label="Incidents">
            <li :for={i <- @open_incidents} class="items-start!">
              <span class="tag shrink-0">{env_label(i.env, @live_only?)}</span>
              <div class="flex-1 min-w-0">
                <div class="truncate text-[var(--err)]" title={i.detail}>{i.title}</div>
                <div class="meta">
                  {i.count}× · {i.status}
                  <.link :if={i.chat_id} patch={"#{@base}/c/#{i.chat_id}"} data-kb="row" class="xlink">chat</.link>
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
                phx-click="resolve_incident"
                phx-value-id={i.id}
                data-kb="row"
                class="btn btn-ghost btn-sm"
              >
                Resolve
              </button>
            </li>
          </ul>
        </div>

        <div :if={@deploys != []}>
          <div class="sec-h"><span class="eyebrow">Deploys</span></div>
          <ul class="hist">
            <li :for={d <- @deploys}>
              <span class="n">#{d.id}</span>
              <span class="t" title={d.intent}>{d.intent}</span>
              <span class="w">{(d.where && env_label(d.where, @live_only?)) || "main"}</span>
              <span class="d">{ago(d.at)}</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :info, :map
  attr :envs, :map, required: true
  attr :live_only?, :boolean, required: true

  defp env_cell(assigns) do
    ~H"""
    <div class="env">
      <div class="flex items-center gap-2.5">
        <span class="eyebrow">{env_label(@name, @live_only?)}</span>
        <span :if={@info} class={["st", st_tone(@info.status)]}>
          <span class="dot"></span>{if @info.deployed, do: env_text(@info), else: "not built"}
        </span>
      </div>
      <div class="tip">
        {if @info && @info.deployed, do: "main ##{@info.deployed}", else: "—"}<small>{env_note(
          @name,
          @info,
          @envs
        )}</small>
      </div>
      <a
        :if={@info}
        class="xlink"
        href={@info.url}
        target="_blank"
        rel="noopener"
        title={"Open #{env_label(@name, @live_only?)} in a new tab"}
      >
        {host(@info.url)}<.icon name="hero-arrow-top-right-on-square" class="size-3" />
      </a>
    </div>
    """
  end

  defp env_note(_name, nil, _envs), do: ""
  defp env_note(_name, %{deployed: nil}, _envs), do: "not built"

  defp env_note("staging", info, envs) do
    if envs["prod"] && envs["prod"].deployed == info.deployed,
      do: "same as prod",
      else: "not on prod yet"
  end

  defp env_note(_name, _info, _envs), do: ""

  defp sync_text(%{promote: id, live_only?: true}) when id != nil,
    do: "Main ##{id} passed its check and is ready to ship."

  defp sync_text(%{promote: id}) when id != nil,
    do: "Staging is ahead of prod: ##{id} is ready to ship."

  defp sync_text(%{auto_promote: true}), do: "Every change that passes ships by itself."
  defp sync_text(%{live_only?: true}), do: "Live runs main's latest shipped change."
  defp sync_text(_assigns), do: "Staging and prod match."

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: ""
  attr :points, :list, required: true

  defp stat(assigns) do
    assigns = assign(assigns, spark: spark(assigns.points))

    ~H"""
    <div class="stat">
      <span class="l">{@label}</span>
      <span class="v">{@value}<span :if={@unit != ""} class="u">{@unit}</span></span>
      <svg
        :if={@spark}
        class="spark"
        width="160"
        height="28"
        viewBox="0 0 160 28"
        role="img"
        aria-label={"#{@label}, last #{length(@points)} minutes"}
      >
        <polyline points={@spark.points}></polyline>
        <circle cx={@spark.x} cy={@spark.y} r="2.5"></circle>
      </svg>
    </div>
    """
  end

  # A sparkline's points in a 160×28 box, the newest point marked.
  defp spark(values) when length(values) < 2, do: nil

  defp spark(values) do
    {min, max} = Enum.min_max(values)
    span = max(max - min, 1)
    step = 154 / (length(values) - 1)

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> {3 + i * step, 25 - (v - min) / span * 22} end)

    {x, y} = List.last(points)

    %{
      points: Enum.map_join(points, " ", fn {x, y} -> "#{fmt(x)},#{fmt(y)}" end),
      x: fmt(x),
      y: fmt(y)
    }
  end

  defp fmt(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  defp memory_pct(%{"total" => total}) when is_integer(total),
    do: min(100, round(total / 1_048_576 / Burrow.Sandbox.memory_mb() * 100))

  defp memory_pct(_stats), do: 0

  defp uptime(nil, _stats), do: "not built"
  defp uptime(%{deployed: nil}, _stats), do: "not built"

  defp uptime(%{status: :running}, %{"uptime" => ms}) when is_integer(ms) do
    minutes = div(ms, 60_000)

    cond do
      minutes < 60 -> "up #{minutes} min"
      minutes < 1440 -> "up #{div(minutes, 60)} h #{rem(minutes, 60)} min"
      true -> "up #{div(minutes, 1440)}d #{div(rem(minutes, 1440), 60)}h"
    end
  end

  defp uptime(%{status: {:crashed, _}}, _stats), do: "down"
  defp uptime(info, _stats), do: env_text(info)

  defp down_text(%{status: {:crashed, _}}, name), do: "#{name} is down"
  defp down_text(info, name), do: "#{name}: #{env_text(info)}"

  defp host(url),
    do: url |> URI.parse() |> then(&"#{&1.host}#{if &1.port not in [80, 443], do: ":#{&1.port}"}")

  defp ago(nil), do: ""

  defp ago(at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)
    today = Date.utc_today()

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      DateTime.to_date(at) == today -> "today"
      DateTime.to_date(at) == Date.add(today, -1) -> "yesterday"
      true -> Calendar.strftime(at, "%b %-d")
    end
  end

  ## Dialogs

  attr :p, :map, required: true
  attr :teams, :list, required: true
  attr :creating, :boolean, required: true

  @doc "A new project: a name, and optionally a git repo, a team and the app's login."
  def new_project_dialog(assigns) do
    team = Enum.find(assigns.teams, &(to_string(&1.id) == assigns.p.team_id))

    assigns =
      assign(assigns,
        slug: slug(assigns.p.name),
        summary:
          Enum.join(
            [(team && team.name) || "Only me"] ++
              if(assigns.p.repo_url != "", do: ["repo"], else: [auth_name(assigns.p.auth)]),
            " · "
          )
      )

    ~H"""
    <.modal id="new-project" title="New project" return_to="new-project-btn">
      <.form
        for={%{}}
        as={:project}
        id="new-project-form"
        phx-change="new_project_change"
        phx-submit="create_project"
        class="flex flex-col gap-4"
      >
        <div>
          <label class="flabel" for="np-name">Name</label>
          <input
            id="np-name"
            name="project[name]"
            type="text"
            class="field"
            autocomplete="off"
            placeholder="Sauna booking"
            value={@p.name}
            phx-mounted={JS.focus()}
            aria-describedby="np-slug"
          />
          <div id="np-slug" class="mono hint">slug: {@slug}</div>
        </div>
        <button
          type="button"
          class="disc"
          aria-expanded={to_string(@p.more)}
          aria-controls="np-more"
          phx-click="toggle_more"
        >
          <.icon name="hero-chevron-right" class={["size-3.5 chev", @p.more && "open"]} />
          Git repo and sharing<span class="k">{@summary}</span>
        </button>
        <div :if={@p.more} id="np-more" class="flex flex-col gap-3.5">
          <div>
            <label class="flabel" for="np-repo">From a git repo <span>(optional)</span></label>
            <input
              id="np-repo"
              name="project[repo_url]"
              type="url"
              class="field"
              autocomplete="off"
              placeholder="https://github.com/you/app.git"
              value={@p.repo_url}
              aria-describedby="np-repo-hint"
            />
            <div id="np-repo-hint" class="mono hint">needs .peon/preview.json for a preview</div>
          </div>
          <div :if={@p.repo_url != ""}>
            <label class="flabel" for="np-token">
              GitHub token <span>(optional for public repos)</span>
            </label>
            <input
              id="np-token"
              name="project[github_token]"
              type="password"
              class="field"
              autocomplete="off"
              value={@p.github_token}
              aria-describedby="np-token-hint"
            />
            <div id="np-token-hint" class="mono hint">
              fine-grained, for this repo: Contents and Pull requests, read and write
            </div>
          </div>
          <div>
            <label class="flabel" for="np-share">Shared with</label>
            <select id="np-share" name="project[team_id]" class="field">
              <option value="">Only me</option>
              <option :for={t <- @teams} value={t.id} selected={to_string(t.id) == @p.team_id}>
                {t.name}
              </option>
            </select>
          </div>
          <div :if={@p.repo_url == ""}>
            <label class="flabel" for="np-auth">Login</label>
            <select id="np-auth" name="project[auth]" class="field">
              <option :for={{value, label} <- auths()} value={value} selected={value == @p.auth}>
                {label}
              </option>
            </select>
          </div>
          <div :if={@p.repo_url == "" and @p.auth == "accounts"}>
            <input type="hidden" name="project[signups]" value="false" />
            <label class="check">
              <input
                id="np-signups"
                name="project[signups]"
                type="checkbox"
                value="true"
                checked={@p.signups}
                aria-describedby="np-signups-hint"
              /> Allow sign-ups
            </label>
            <div id="np-signups-hint" class="mono hint">
              {if @p.signups,
                do: "anyone can make an account; the first one is the admin",
                else: "the first account is the admin and adds everyone else"}
            </div>
          </div>
          <div :if={@p.repo_url == "" and @p.auth == "basic"} class="flex flex-col gap-3.5">
            <div>
              <label class="flabel" for="np-user">Username</label>
              <input
                id="np-user"
                name="project[basic_username]"
                type="text"
                class="field"
                autocomplete="off"
                value={@p.basic_username}
              />
            </div>
            <div>
              <label class="flabel" for="np-pass">Password <span>(at least 8 characters)</span></label>
              <input
                id="np-pass"
                name="project[basic_password]"
                type="password"
                class="field"
                autocomplete="new-password"
                value={@p.basic_password}
              />
            </div>
          </div>
        </div>
        <div class="flex justify-end items-center gap-2">
          <button type="button" class="btn btn-ghost" phx-click="close_dialog">Cancel</button>
          <button type="submit" class="btn btn-primary" disabled={@p.name == "" or @creating}>
            {if @creating, do: "Creating…", else: "Create"}
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  defp auths,
    do: [
      {"accounts", "User accounts"},
      {"basic", "One username and password"},
      {"open", "Open, no login"}
    ]

  defp auth_name(auth), do: auths() |> List.keyfind(auth, 0, {nil, "User accounts"}) |> elem(1)

  # The slug Burrow makes of a name (`Burrow.Projects.slug_base/1`).
  defp slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 30)

    cond do
      base == "" -> "…"
      base =~ ~r/^[a-z]/ -> base
      true -> "app_" <> base
    end
  end

  attr :sharing, :map, required: true
  attr :project, :map

  def share_dialog(assigns) do
    ~H"""
    <.modal id="share" title={"Share #{@project && @project.name}"} return_to="more-btn">
      <%= if @sharing.owner? do %>
        <.form for={%{}} as={:share} id="share-form" phx-submit="share" class="flex flex-col gap-4">
          <div>
            <label class="flabel" for="share-team">Shared with</label>
            <select id="share-team" name="share[team_id]" class="field">
              <option value="">Only me</option>
              <option
                :for={t <- @sharing.teams}
                value={t.id}
                selected={@sharing.team && @sharing.team.id == t.id}
              >
                {t.name}
              </option>
            </select>
            <div class="hint">
              Everyone in the team can open it, chat in it and restart it. It runs on your AI login.
            </div>
          </div>
          <div class="flex justify-end items-center gap-2">
            <button type="button" class="btn btn-ghost" phx-click="close_dialog">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      <% else %>
        <p class="m-0 text-[var(--text-2)]">
          {if @sharing.team, do: "Shared with #{@sharing.team.name}.", else: "Not shared."} Only the project's owner can change that.
        </p>
        <div class="flex justify-end">
          <button type="button" class="btn btn-secondary" phx-click="close_dialog">Close</button>
        </div>
      <% end %>
    </.modal>
    """
  end

  attr :sharing, :map, required: true
  attr :project, :map

  def hand_over_dialog(assigns) do
    ~H"""
    <.modal id="hand-over" title={"Hand over #{@project && @project.name}"} return_to="more-btn">
      <.form
        for={%{}}
        as={:hand_over}
        id="hand-over-form"
        phx-submit="hand_over"
        class="flex flex-col gap-4"
      >
        <div>
          <label class="flabel" for="hand-over-user">New owner</label>
          <select id="hand-over-user" name="hand_over[user_id]" class="field">
            <option :for={u <- @sharing.teammates} value={u.id}>{u.email}</option>
          </select>
          <div class="hint">
            It runs on their AI login from then on, and only they can share it or hand it on.
          </div>
        </div>
        <div class="flex justify-end items-center gap-2">
          <button type="button" class="btn btn-ghost" phx-click="close_dialog">Cancel</button>
          <button type="submit" class="btn btn-primary" data-confirm="Hand this project over?">
            Hand over
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :secrets, :list, required: true
  attr :key, :integer, required: true

  def secrets_dialog(assigns) do
    ~H"""
    <.modal id="secrets-panel" title="Secrets" return_to="more-btn">
      <p class="meta m-0">
        API keys, tokens and passwords. The preview, staging and prod get each one as an
        environment variable and restart when one changes. The agent sees names only.
      </p>
      <ul class="rows max-h-[50vh] overflow-y-auto">
        <li :if={@secrets == []} class="muted">No secrets yet.</li>
        <li :for={s <- @secrets} class="items-start!">
          <div class="flex-1 min-w-0 flex flex-col gap-1.5">
            <div class="flex items-center gap-2">
              <span class="mono font-medium">{s.name}</span>
              <span class={["st", if(s.set?, do: "ok", else: "warn")]}>
                <span class="dot"></span>{if s.set?, do: "set", else: "asked for"}
              </span>
            </div>
            <span :if={s.why} class="meta">{s.why}</span>
            <.form
              for={%{}}
              id={"secret-#{s.name}-#{@key}"}
              phx-submit="set_secret"
              class="flex gap-2"
            >
              <input type="hidden" name="name" value={s.name} />
              <input
                type="password"
                name="value"
                class="field h-8!"
                autocomplete="off"
                required
                placeholder={if s.set?, do: "New value", else: "Value"}
                aria-label={"Value for #{s.name}"}
              />
              <button class="btn btn-secondary btn-sm" data-kb="row">
                {if s.set?, do: "Replace", else: "Save"}
              </button>
            </.form>
          </div>
          <button
            phx-click="delete_secret"
            phx-value-name={s.name}
            data-kb="row"
            data-confirm={"Remove #{s.name}? The app loses it on its next restart."}
            class="btn btn-ghost btn-sm"
          >
            Remove
          </button>
        </li>
      </ul>
      <.form for={%{}} id={"secret-new-#{@key}"} phx-submit="set_secret" class="flex flex-col gap-2">
        <span class="eyebrow">Add a secret</span>
        <input
          type="text"
          name="name"
          class="field mono"
          placeholder="NAME, like SLACK_TOKEN"
          autocomplete="off"
          required
          aria-label="Name"
        />
        <input
          type="password"
          name="value"
          class="field"
          placeholder="Value"
          autocomplete="off"
          required
          aria-label="Value"
        />
        <div class="flex justify-end items-center gap-2">
          <button type="button" class="btn btn-ghost" phx-click="close_dialog">Close</button>
          <button class="btn btn-primary btn-sm" data-kb="row">Add</button>
        </div>
      </.form>
    </.modal>
    """
  end

  ## Secrets in the chat

  @doc "Secrets the agent asked for that nobody has set yet (for one chat, or all)."
  def asked(secrets, chat_id \\ nil),
    do: Enum.filter(secrets, &(not &1.set? and (chat_id == nil or &1.chat_id == chat_id)))

  defp secrets_text(secrets) do
    case {length(secrets), length(asked(secrets))} do
      {0, _} -> "none"
      {n, 0} -> "#{n} set"
      {n, a} -> "#{n - a} set · #{a} asked for"
    end
  end

  attr :secrets, :list, required: true
  attr :key, :integer, required: true

  @doc "In the chat: the keys the agent asked for, with a box to paste each into."
  def connect_card(assigns) do
    ~H"""
    <section class="framed ws-connect" aria-label="Keys the app needs">
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="m-0 text-[15px] font-semibold">Peon needs a key</h2>
        <span class="meta">kept in Peon, never in the code</span>
      </div>
      <.form
        :for={s <- @secrets}
        for={%{}}
        id={"connect-#{s.name}-#{@key}"}
        phx-submit="set_secret"
        class="ws-connect-row"
      >
        <input type="hidden" name="name" value={s.name} />
        <label class="flex flex-col min-w-0 flex-1 gap-1">
          <span class="mono text-[13px] font-medium">{s.name}</span>
          <span :if={s.why} class="meta">{s.why}</span>
          <input
            type="password"
            name="value"
            class="field"
            autocomplete="off"
            required
            aria-label={"Value for #{s.name}"}
          />
        </label>
        <button class="btn btn-primary btn-sm" data-kb="row">Save</button>
      </.form>
    </section>
    """
  end

  ## The thread

  @doc """
  A Peon turn's messages as the thread shows them: its tool calls in folds
  of steps, each titled by what the agent said before them (a preamble or
  progress note), and its answer, the text no tool call follows. Peon's
  notes, after which it kept going, and errors stand on their own.
  `[{:steps, said | nil, tools} | {:say, m} | {:note, m} | {:error, m}]`
  """
  def turn_items(messages) do
    {items, said, fold} =
      Enum.reduce(messages, {[], nil, nil}, fn
        %{role: :tool} = m, {items, said, nil} ->
          {items, nil, {said, [m]}}

        %{role: :tool} = m, {items, nil, {title, tools}} ->
          {items, nil, {title, [m | tools]}}

        %{role: :assistant} = m, {items, said, fold} ->
          {close(items, said, fold), m, nil}

        %{role: role} = m, {items, said, fold} ->
          {[{kind(role), m} | close(items, said, fold)], nil, nil}
      end)

    items |> close(said, fold) |> Enum.reverse()
  end

  defp close(items, said, fold) do
    items =
      if fold, do: [{:steps, elem(fold, 0), Enum.reverse(elem(fold, 1))} | items], else: items

    if said, do: [{:say, said} | items], else: items
  end

  defp kind(:note), do: :note
  defp kind(_role), do: :error

  attr :block, :any, required: true
  attr :images, :string, default: nil, doc: "where the chat's images are (ChatImageController)"
  attr :live, :boolean, default: false, doc: "the turn the agent is on"

  def block(%{block: {:user, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <div :if={@images && @message[:images] not in [nil, []]} class="bubble-imgs">
      <a :for={name <- @message.images} href={"#{@images}/#{name}"} target="_blank">
        <img src={"#{@images}/#{name}"} alt="An image sent with the message" loading="lazy" />
      </a>
    </div>
    <div class="bubble-user">{@message.text}</div>
    """
  end

  @edits ~w(edit write patch apply_patch multiedit)

  # A Peon turn (`BurrowWeb.WorkspaceLive`'s blocks), the quiet column: the
  # peon and what it says, then one line for its steps, to open. Peon's notes
  # (it kept going) and errors split the turn into parts, each with its own
  # line. The live part says what the agent said last while it works.
  def block(%{block: {:peon, items, ack?}} = assigns) do
    parts =
      items
      |> quiet_parts(assigns.live)
      |> Enum.with_index()
      |> Enum.map(fn {part, i} ->
        texts =
          for {m, j} <- Enum.with_index(part[:says] || []),
              do: say_text(m, ack? and i == 0 and j == 0)

        Map.put(part, :texts, texts)
      end)

    drawn =
      for %{tools: tools} <- parts,
          %{text: text} <- tools,
          path <- Burrow.Design.drawn(text),
          uniq: true,
          do: String.replace_prefix(path, "design/", "")

    assigns = assign(assigns, parts: parts, ack?: ack?, drawn: drawn)

    ~H"""
    <div class="say-peon-turn">
      <Layouts.mark size={22} />
      <div class="flex-1 min-w-0 flex flex-col gap-1">
        <p :if={@ack? and not match?([%{says: [_ | _]} | _], @parts)} class="say-agent">Zug zug.</p>
        <%= for part <- @parts do %>
          <div :if={part[:note]} class="evt note" role="note">
            <span class="ln"></span>
            <span class="mono">
              <.icon name="hero-arrow-path" class="size-3" /> {note_text(part.note)}
            </span>
            <span class="ln"></span>
          </div>
          <div :if={part[:error]} class="say-error">{part.error.text}</div>
          <p :for={text <- part[:texts] || []} class="say-agent">{text}</p>
          <.steps :if={part[:tools] not in [nil, []]} tools={part.tools} live={part.live} />
        <% end %>
        <div :if={@drawn != []} class="blink">
          <button type="button" phx-click="view" phx-value-view="design">Open Design</button>
          · {drawn_text(@drawn)}
        </div>
      </div>
    </div>
    """
  end

  # What the agent said, its own "Zug zug." off; the turn's first words get
  # Peon's, when it answers the user.
  defp say_text(message, ack?) do
    text = String.replace(message.text, ~r/\A\s*zug zug\.?\s*/i, "")
    if ack?, do: "Zug zug. " <> text, else: text
  end

  defp drawn_text([one]), do: "#{one} is in Design."

  defp drawn_text(names) do
    {init, [last]} = Enum.split(names, -1)
    "#{Enum.join(init, ", ")} and #{last} are in Design."
  end

  # A turn's items (`turn_items/1`) in parts: `%{says, tools, live}`, or a
  # note or error on its own. A part's answer is what the agent said after
  # its last step; while the turn is live, what it said last stands in.
  defp quiet_parts(items, live?) do
    items
    |> Enum.chunk_by(&(elem(&1, 0) in [:note, :error]))
    |> Enum.flat_map(fn
      [{kind, _} | _] = notes when kind in [:note, :error] ->
        Enum.map(notes, fn {kind, m} -> %{kind => m} end)

      part ->
        tools = for {:steps, _said, tools} <- part, tool <- tools, do: tool
        says = for {:say, m} <- part, do: m
        said = for {:steps, said, _tools} <- part, said != nil, do: said
        [%{says: says, said: List.last(said), tools: tools}]
    end)
    |> then(fn parts ->
      last = length(parts) - 1

      parts
      |> Enum.with_index()
      |> Enum.map(fn
        {%{says: says} = part, i} ->
          live = live? and i == last
          says = if says == [] and live and part.said, do: [part.said], else: says
          Map.merge(part, %{says: says, live: live})

        {part, _i} ->
          part
      end)
    end)
  end

  attr :tools, :list, required: true
  attr :live, :boolean, default: false

  # "Worked through 10 steps · 2 files changed", opening to the steps. Its
  # id says whether it is live, so it folds again once the agent moved on.
  defp steps(assigns) do
    edited =
      assigns.tools
      |> Enum.map(&split_tool(&1.text))
      |> Enum.filter(&(elem(&1, 0) in @edits))
      |> Enum.flat_map(&String.split(elem(&1, 1), " ", trim: true))
      |> Enum.uniq()
      |> length()

    n = length(assigns.tools)

    assigns =
      assign(assigns,
        runs: Enum.chunk_by(assigns.tools, &{&1.text, &1[:status]}),
        line:
          Enum.join(
            [
              "#{if assigns.live, do: "Working through", else: "Worked through"} #{n} #{if n == 1, do: "step", else: "steps"}"
            ] ++
              if(edited > 0,
                do: ["#{edited} #{if edited == 1, do: "file", else: "files"} changed"],
                else: []
              ),
            " · "
          )
      )

    ~H"""
    <details
      id={"steps-#{hd(@tools).id}-#{if @live, do: "live", else: "done"}"}
      class="qsteps"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="qline">
        <span>{@line}</span><.icon name="hero-chevron-right" class="size-3.5 chev" />
      </summary>
      <div class="qlist-steps">
        <.step
          :for={{run, i} <- Enum.with_index(@runs)}
          message={hd(run)}
          count={length(run)}
          now={@live and i == length(@runs) - 1}
        />
      </div>
    </details>
    """
  end

  attr :message, :map, required: true
  attr :count, :integer, required: true, doc: "the same call this many times in a row"
  attr :now, :boolean, default: false, doc: "the step the agent is on"

  # A step: what it did in words over the file or command, its output to
  # open when Peon's tools or a failure left one.
  defp step(assigns) do
    {icon, what, where} = step_words(assigns.message)

    assigns =
      assign(assigns,
        icon: icon,
        what: what,
        where: where,
        err?: assigns.message[:status] == "error",
        out: assigns.message[:detail] not in [nil, ""]
      )

    ~H"""
    <details
      :if={@out}
      class="result"
      open={@message[:peon?]}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class={["srow", @err? && "err", @now && "now"]}>
        <.step_line icon={@icon} what={@what} where={@where} count={@count} />
      </summary>
      <pre class={["out mono", @message[:peon?] && "peon"]}>{@message.detail}</pre>
    </details>
    <div :if={!@out} class={["srow", @err? && "err", @now && "now"]}>
      <.step_line icon={@icon} what={@what} where={@where} count={@count} />
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :what, :string, required: true
  attr :where, :string, required: true
  attr :count, :integer, required: true

  defp step_line(assigns) do
    ~H"""
    <span class="si"><.icon name={@icon} class="size-3.5" /></span>
    <span class="sw">
      <span class="sa">{@what}<span :if={@count > 1} class="sx">×{@count}</span></span>
      <span :if={@where != ""} class="sb mono">{@where}</span>
    </span>
    """
  end

  # A step in words, `{icon, what, where}`: "Read chat.ex" in lib/burrow,
  # "Run the tests" with `mix test`.
  defp step_words(message) do
    case split_tool(message.text) do
      {"read", path} ->
        {"hero-document-text", "Read #{Path.basename(path)}", dir(path)}

      {"bash", rest} ->
        about = message[:about]
        command = if about, do: String.replace_suffix(rest, " " <> about, ""), else: rest
        {"hero-command-line", about || command_words(command), command}

      {tool, paths} when tool in @edits ->
        paths = String.split(paths, " ", trim: true)
        names = Enum.map_join(paths, ", ", &Path.basename/1)
        {"hero-pencil", "Changed #{names}", dir(List.first(paths, ""))}

      {"grep", rest} ->
        {"hero-magnifying-glass", "Searched the code", rest}

      {"glob", rest} ->
        {"hero-magnifying-glass", "Looked for files", String.replace_prefix(rest, "/app ", "")}

      {"list", rest} ->
        {"hero-folder", "Listed a folder", rest}

      {tool, rest} when tool in ~w(webfetch websearch) ->
        {"hero-globe-alt", "Looked on the web", rest}

      {tool, _rest} when tool in ~w(todowrite todoread) ->
        {"hero-list-bullet", "Updated the plan", ""}

      {"peon_" <> _ = tool, rest} ->
        {"hero-sparkles", peon_words(tool), rest}

      {tool, rest} ->
        {"hero-wrench", tool, rest}
    end
  end

  # A path's folder in the agent's checkout (/app in its container).
  defp dir(path) do
    case path |> String.replace_prefix("/app/", "") |> Path.dirname() do
      dir when dir in [".", "/app", "/"] -> ""
      dir -> dir <> "/"
    end
  end

  defp command_words(command) do
    cond do
      command =~ "mix test" -> "Ran the tests"
      command =~ "mix format" -> "Tidied up"
      command =~ ~r/mix (compile|deps)|npm (install|ci)/ -> "Built"
      command =~ "curl" -> "Looked at the page"
      command =~ ~r/\Atk (close|done)\b/ -> "Closed a ticket"
      command =~ ~r/\Atk (show)\b/ -> "Read a ticket"
      command =~ ~r/\Atk (create|add)\b/ -> "Added a ticket"
      command =~ ~r/\Atk\b/ -> "Looked at the queue"
      command =~ ~r/\A(cat|head|tail|less|ls|find|tree|wc|sed -n)\b/ -> "Looked at files"
      command =~ ~r/\A(grep|rg)\b/ -> "Searched the code"
      command =~ ~r/\Agit\b/ -> "Used git"
      true -> "Ran a command"
    end
  end

  defp peon_words("peon_submit_changeset"), do: "Checked and handed in the change"
  defp peon_words("peon_restart_preview"), do: "Restarted the preview"
  defp peon_words("peon_runtime"), do: "Checked the running app"
  defp peon_words("peon_secrets"), do: "Checked the keys"
  defp peon_words("peon_request_secret"), do: "Asked you for a key"
  defp peon_words(tool), do: tool

  defp note_text(%{kind: "queue", text: text}) do
    case Regex.run(~r/(\d+) unfinished tickets?/, text) do
      [_, "1"] -> "on to the last ticket in the queue"
      [_, n] -> "on to the next ticket, #{n} left in the queue"
      nil -> "on to the next ticket"
    end
  end

  defp note_text(%{text: text}),
    do: text |> String.split("\n", parts: 2) |> hd() |> String.trim_trailing(":")

  @doc """
  A tool line's name and the rest: `"edit lib/a.ex"` -> `{"edit", "lib/a.ex"}`.
  Names are opencode's: its `shell` is `bash`, and Peon's tools called from
  code (`peon.submit_changeset`) are `peon_submit_changeset`.
  """
  def split_tool(text) do
    {name, rest} =
      case String.split(text, " ", parts: 2) do
        [name, rest] -> {name, rest}
        [name] -> {name, ""}
      end

    case name do
      "shell" -> {"bash", rest}
      "peon." <> tool -> {"peon_" <> tool, rest}
      name -> {name, rest}
    end
  end

  ## Words and tones

  def env_text(%{status: :watching, deploy: %{target: id}}), do: "watching ##{id}"
  def env_text(%{status: :loading, deploy: %{target: id}}), do: "hot-loading ##{id}"
  def env_text(%{status: :booting, deploy: %{target: id}}), do: "starting ##{id}"
  def env_text(%{status: {:crashed, _}}), do: "down"
  def env_text(%{status: status}), do: to_string(status)

  @doc "A status's tone: ok, warn, idle or err."
  def st_tone(:running), do: "ok"

  def st_tone(status) when status in [:starting, :loading, :booting, :watching, :attaching],
    do: "warn"

  def st_tone(status) when status in [nil, :stopped, :no_pack, :off], do: "idle"
  def st_tone(_), do: "err"

  defp preview_word({:crashed, _}), do: "stopped"
  defp preview_word(:no_pack), do: "no preview"
  defp preview_word({:pack_error, _}), do: "pack error"
  defp preview_word(status), do: to_string(status)

  defp mb(nil), do: "?"
  defp mb(bytes), do: div(bytes, 1_048_576)
end
