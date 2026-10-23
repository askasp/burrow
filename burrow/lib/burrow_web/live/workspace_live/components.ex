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
  attr :collapsed, :boolean, required: true
  attr :theme, :string, required: true
  attr :nothing_built?, :boolean, required: true
  attr :repo?, :boolean, required: true
  attr :live_only?, :boolean, required: true

  @doc """
  The project switcher on top: the project's tile with its health bar
  (`Burrow.Activity`), opening every project the user can open. Then New
  chat, the chats still open (what needs the user first) and the done ones
  by day. Collapses to a strip of the tile, New chat and a dot per open
  chat; on phones it slides in from the left.
  """
  def drawer(assigns) do
    open = open_chats(assigns.tabs, assigns.live_only?)

    assigns =
      assign(assigns,
        open: open,
        done: assigns.tabs |> Enum.filter(&Activity.done?(&1, assigns.live_only?)) |> by_day(),
        tile: Enum.find(assigns.rail, & &1.current) || %{state: "stopped", pct: 8},
        full?: length(open) >= Chats.max()
      )

    ~H"""
    <nav
      id="drawer"
      class={["drawer", @collapsed && "closed"]}
      aria-label="Project and chats"
      phx-hook=".Drawer"
      data-kb-zoom-hide
    >
      <div class="dtop">
        <div class="menuw pmw">
          <button
            id="project-switch"
            type="button"
            class="pswitch"
            aria-haspopup="menu"
            aria-expanded="false"
            aria-label={"#{@project.name}, switch project"}
            title="Switch project (⌃B P)"
            phx-click={
              JS.toggle(to: "#project-menu")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
            data-kb-key="P"
            data-kb-label="Switch project"
            data-kb-group="Projects"
          >
            <.tile name={@project.name} state={@tile.state} pct={@tile.pct} />
            <span class="pn">
              <span class="nm">{@project.name}</span><span class="mm">{@status}</span>
            </span>
            <.icon name="hero-chevron-down" class="size-[14px] shrink-0 pchev" />
          </button>
          <div
            id="project-menu"
            class="pmenu"
            role="menu"
            aria-label="Projects"
            style="display: none"
            phx-click-away={hide_projects()}
          >
            <div class="msec">Projects</div>
            <.link
              :for={p <- @rail}
              navigate={p.url}
              class="pmrow"
              role="menuitem"
              aria-current={if p.current, do: "page"}
            >
              <.tile name={p.name} state={p.state} pct={p.pct} />
              <span class="pn">
                <span class="nm">{p.name}</span>
                <span class={["lbl", p.state]}>
                  <span :if={p.state == "working"} class="swing" aria-hidden="true">
                    <.icon name="hero-wrench" class="size-3" />
                  </span>{p.label}
                </span>
              </span>
              <.icon :if={p.current} name="hero-check" class="size-[13px] shrink-0" />
            </.link>
            <div class="msep" role="separator"></div>
            <button
              id="new-project-btn"
              type="button"
              class="pmrow"
              role="menuitem"
              aria-haspopup="dialog"
              phx-click={
                hide_projects()
                |> JS.remove_class("show-drawer", to: ".ws-root")
                |> JS.push("dialog", value: %{dialog: "new_project"})
              }
              data-kb-key="N"
              data-kb-label="New project"
              data-kb-group="Projects"
            >
              <.icon name="hero-plus" class="size-4 shrink-0" />New project
            </button>
            <.link class="pmrow" role="menuitem" navigate={~p"/projects"}>
              <.icon name="hero-squares-2x2" class="size-4 shrink-0" />All projects
            </.link>
          </div>
        </div>
        <button
          type="button"
          class="icon-btn dhide"
          phx-click="toggle_drawer"
          aria-label="Hide chats"
          aria-expanded="true"
          title="Hide chats (⌃B H)"
          data-kb-key="h"
          data-kb-label="Hide or show chats"
          data-kb-group="Chats"
        >
          <.icon name="hero-chevron-double-left" class="size-4" />
        </button>
      </div>
      <span class="ncw" title={if @full?, do: full_text(), else: "New chat (⌃B C)"}>
        <button
          id="new-chat"
          type="button"
          class="newchat"
          aria-label="New chat"
          phx-click="new_chat"
          disabled={@full?}
          data-kb-key="c"
          data-kb-label="New chat"
          data-kb-group="Chats"
          data-kb-focus="#chat-input"
        >
          <.icon name="hero-plus" class="size-4 shrink-0" /><span class="dt">New chat</span><kbd>⌃B C</kbd>
        </button>
      </span>
      <div class="dscroll">
        <div class="dsec">
          <span>Open</span><span class="mono">{length(@open)} of {Chats.max()}</span>
        </div>
        <.chat_row
          :for={t <- @open}
          tab={t}
          url={"#{@base}/c/#{t.chat.id}"}
          current={@chat != nil and @chat.id == t.chat.id}
          title={chat_title(t, @project, @nothing_built?)}
          sub={sub(t, @live_only?)}
          confirm={close_confirm(t, @repo?)}
        />
        <p :if={@open == []} class="dnone">Nothing open. Start a new chat for the next change.</p>
        <div :for={{day, tabs} <- @done} class="dday">
          <div class="dsec"><span>{day}</span></div>
          <.chat_row
            :for={t <- tabs}
            tab={t}
            url={"#{@base}/c/#{t.chat.id}"}
            current={@chat != nil and @chat.id == t.chat.id}
            title={chat_title(t, @project, @nothing_built?)}
            sub={sub(t, @live_only?)}
            done
          />
        </div>
      </div>
      <div class="dbot">
        <Layouts.mark size={22} />
        <.link class="dlink" navigate={~p"/projects"} title="Projects, teams and AI login">
          Account
        </.link>
        <button
          type="button"
          class="icon-btn dtheme"
          phx-click="theme"
          title={"Theme: #{theme_name(@theme)}. Click for #{theme_name(next_theme(@theme))}."}
          aria-label={"Theme: #{theme_name(@theme)}"}
        >
          <.icon name={theme_icon(@theme)} class="size-4" />
        </button>
        <button
          type="button"
          class="icon-btn dshow"
          phx-click="toggle_drawer"
          aria-label="Show chats"
          aria-expanded="false"
          title="Show chats (⌃B H)"
          data-kb-key="h"
          data-kb-label="Hide or show chats"
          data-kb-group="Chats"
        >
          <.icon name="hero-chevron-double-right" class="size-4" />
        </button>
      </div>
    </nav>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Drawer">
      // On phones the drawer covers the page: picking a chat or a project
      // puts it away. (A patch link stops LiveView's own phx-click.)
      export default {
        mounted() {
          this.el.addEventListener("click", e => {
            if (e.target.closest("a")) this.js().removeClass(this.el.closest(".ws-root"), "show-drawer")
          })
        }
      }
    </script>
    """
  end

  attr :tab, :map, required: true
  attr :url, :string, required: true
  attr :current, :boolean, required: true
  attr :title, :string, required: true
  attr :sub, :string, required: true
  attr :done, :boolean, default: false
  attr :confirm, :string, default: nil

  defp chat_row(assigns) do
    ~H"""
    <div id={"chat-#{@tab.chat.id}"} class={["crow", @done && "past"]} data-on={to_string(@current)}>
      <.link
        patch={@url}
        class="crb"
        aria-current={@current && "page"}
        data-kb="item"
        title={"#{if number(@tab), do: "##{number(@tab)} · "}#{@title} · #{@sub}"}
      >
        <span :if={@done} class="okic" aria-hidden="true">
          <.icon name="hero-check" class="size-[13px]" />
        </span>
        <span :if={!@done} class={["cdot", dot(@tab.phase)]} aria-hidden="true"></span>
        <span class="cb">
          <span class="ct">
            <span :if={number(@tab)} class="n">#{number(@tab)}</span><span class="tt">{@title}</span>
          </span>
          <span class={["cs2", !@done && dot(@tab.phase)]}>{@sub}</span>
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

  # A project's initial, its health bar along the bottom.
  defp tile(assigns) do
    ~H"""
    <span class="ri" aria-hidden="true">
      {initial(@name)}<span class={["rhp", @state]}><i style={"width: #{@pct}%"}></i></span>
    </span>
    """
  end

  defp hide_projects,
    do:
      JS.hide(to: "#project-menu")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#project-switch")

  @doc "Why New chat is off."
  def full_text, do: "#{Chats.max()} changes are open. Merge or discard one first."

  @doc """
  The chats that aren't done, what needs the user first: failed checks, a
  pull request or staging to look at; then the working ones; empty ones last.
  """
  def open_chats(tabs, live_only?),
    do: tabs |> Enum.reject(&Activity.done?(&1, live_only?)) |> Enum.sort_by(&need(&1.phase))

  defp need(phase) when phase in ~w(failed ready staged), do: 0
  defp need(phase) when phase in ~w(working landing), do: 1
  defp need("new"), do: 3
  defp need(_phase), do: 2

  @days ["Today", "Yesterday", "This week", "Older"]

  # Done chats, newest change first, by the day it went out.
  defp by_day(tabs) do
    tabs
    |> Enum.sort_by(& &1.draft.change, :desc)
    |> Enum.group_by(&day/1)
    |> Enum.sort_by(fn {day, _tabs} -> Enum.find_index(@days, &(&1 == day)) end)
  end

  # When a done chat's change was submitted, in the drawer's words.
  defp day(tab) do
    case Date.diff(Date.utc_today(), DateTime.to_date(at(tab))) do
      n when n <= 0 -> "Today"
      1 -> "Yesterday"
      n when n < 7 -> "This week"
      _ -> "Older"
    end
  end

  defp at(%{draft: %{at: at}}) do
    {:ok, at, _offset} = DateTime.from_iso8601(at)
    at
  end

  # The line under a chat's title: where its change stands.
  defp sub(%{phase: "live"} = t, live_only?),
    do: "#{if live_only?, do: "live", else: "on prod"} · #{ago(at(t))}"

  defp sub(%{phase: "landing"} = t, true), do: "on main · #{ago(at(t))}"
  defp sub(%{phase: "working", draft: %{status: "checking"}}, _live_only?), do: "checking"
  defp sub(%{phase: "staged"}, _live_only?), do: "on staging · ship"
  defp sub(%{phase: phase}, _live_only?), do: phase_text(phase)

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

  defp phase_text("working"), do: "working"
  defp phase_text("failed"), do: "checks failed"
  defp phase_text("ready"), do: "pull request open"
  defp phase_text("drawn"), do: "boards on main"
  defp phase_text("landing"), do: "on main"
  defp phase_text("idle"), do: "nothing submitted yet"
  defp phase_text(_), do: "new chat"

  defp dot(phase) when phase in ~w(working landing), do: "working"
  defp dot(phase) when phase in ~w(ready staged failed), do: "waiting"
  defp dot(phase) when phase in ~w(live drawn), do: "done"
  defp dot(_), do: "new"

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

  defp theme_name("light"), do: "Light"
  defp theme_name("dark"), do: "Dark"
  defp theme_name(_), do: "System theme"

  defp theme_icon("light"), do: "hero-sun"
  defp theme_icon("dark"), do: "hero-moon"
  defp theme_icon(_), do: "hero-computer-desktop"

  defp next_theme("system"), do: "light"
  defp next_theme("light"), do: "dark"
  defp next_theme(_), do: "system"

  defp initial(name), do: name |> to_string() |> String.first() |> to_string() |> String.upcase()

  ## Chat bar

  attr :title, :string, required: true, doc: "the open chat's"
  attr :number, :integer, default: nil, doc: "its change's, once on main"
  attr :project, :map
  attr :meta, :string, required: true
  attr :overview, :boolean, required: true
  attr :sharing, :map
  attr :live_only?, :boolean, required: true
  attr :repo?, :boolean, required: true
  attr :secrets, :list, required: true
  attr :open_incidents, :integer, required: true
  attr :pane, :string, required: true
  attr :preview, :map, required: true
  attr :view, :string, required: true
  attr :agent?, :boolean, required: true, doc: "the open chat's agent runs"

  @doc """
  The open chat, the project's versions beside it, \"Deploys and usage\",
  and the project's ⋯ menu. On phones the menu also holds what the bars
  show on a wide screen.
  """
  def chat_bar(assigns) do
    ~H"""
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
        <h1 class="pbar-name">
          <span :if={@number} class="mono pbar-n">#{@number}</span><span class="pbar-t">{@title}</span>
        </h1>
        <span class="mono pbar-meta">{@meta}</span>
      </div>
      <div class="pbar-acts">
        <div class="seg ws-panes" role="group" aria-label="View">
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
        <button
          :if={!@repo?}
          id="overview-btn"
          type="button"
          aria-label="Deploys and usage"
          class="btn btn-secondary btn-sm"
          aria-pressed={to_string(@overview)}
          phx-click="toggle_overview"
          data-kb-key="s"
          data-kb-label="Deploys and usage"
          data-kb-group="Ship"
        >
          <.icon name="hero-chart-bar" class="size-[15px]" />
          <span class="pbar-long">Deploys and usage</span>
          <span :if={@open_incidents > 0} class="cnt" title="Open incidents">{@open_incidents}</span>
        </button>
        <div class="menuw">
          <button
            id="more-btn"
            type="button"
            class="icon-btn"
            aria-label={"More for #{@project && @project.name}"}
            aria-haspopup="menu"
            aria-expanded="false"
            phx-click={
              JS.toggle(to: "#more-menu")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            }
          >
            <.icon name="hero-ellipsis-horizontal" class="size-5" />
          </button>
          <div
            id="more-menu"
            class="menu"
            role="menu"
            style="display: none"
            phx-click-away={hide_menu()}
          >
            <div class="menu-meta phone-only mono">{@meta}</div>
            <button
              :if={!@repo?}
              type="button"
              role="menuitem"
              class="phone-only"
              phx-click={hide_menu() |> JS.push("toggle_overview")}
            >
              {if @overview, do: "Back to preview", else: "Deploys and usage"}<span
                :if={@open_incidents > 0}
                class="k text-[var(--err)]"
              >{@open_incidents} incidents</span>
            </button>
            <button
              :if={@preview.url && !@preview[:empty]}
              type="button"
              role="menuitem"
              class="phone-only"
              phx-click={hide_menu() |> JS.push("reload_preview")}
            >
              Reload preview
            </button>
            <a
              :if={@preview.url && !@preview[:empty]}
              href={@preview.url}
              target="_blank"
              rel="noopener"
              role="menuitem"
              class="phone-only"
            >
              Open {if @view == "dev", do: "the preview", else: "the app"} in a new tab
            </a>
            <button
              :if={@preview.url && !@preview[:empty]}
              type="button"
              role="menuitem"
              class="phone-only"
              phx-click={hide_menu() |> JS.push("toggle_logs")}
            >
              Logs
            </button>
            <button
              :if={@view == "dev" and @agent?}
              type="button"
              role="menuitem"
              class="phone-only"
              phx-click={hide_menu() |> JS.push("restart_preview")}
            >
              Restart the preview
            </button>
            <button
              :if={@agent?}
              type="button"
              role="menuitem"
              class="phone-only"
              phx-click={hide_menu() |> JS.push("toggle_attach")}
            >
              Open in opencode
            </button>
            <div class="msep phone-only" role="separator"></div>
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
      </div>
    </div>
    """
  end

  defp add_envs?(assigns),
    do:
      assigns.live_only? and not assigns.repo? and
        (assigns.sharing == nil or assigns.sharing.owner?)

  defp hide_menu,
    do: JS.hide(to: "#more-menu") |> JS.set_attribute({"aria-expanded", "false"}, to: "#more-btn")

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
  The chat's queue: the agent's tk tickets and those the user added
  ("Queue" in the box), the one in progress first. Tickets that haven't
  started can be deleted; the agent takes the rest one by one.
  """
  def queue_card(assigns) do
    {closed, open} = Enum.split_with(assigns.tickets, &(&1.status == "closed"))
    assigns = assign(assigns, open: open, closed: closed)

    ~H"""
    <details id="queue" class="framed ws-queue" open={@open != []}>
      <summary class="qhead">
        <.icon name="hero-chevron-right" class="size-3.5 chev" />
        <span class="font-medium">Queue</span>
        <span class="muted">{queue_count(@open, @closed)}</span>
        <button
          :if={!@busy? && @open != []}
          id="work-queue"
          type="button"
          class="btn btn-secondary btn-sm ml-auto"
          phx-click="work_queue"
        >
          Work the queue
        </button>
      </summary>
      <ul class="qlist">
        <li :for={t <- @open} id={"ticket-#{t.id}"} class={["qrow", t.status]}>
          <span class="qi">
            <.icon
              name={if t.status == "in_progress", do: "hero-arrow-path", else: "hero-stop"}
              class={["size-3.5", t.status == "in_progress" && "spin"]}
            />
          </span>
          <span class="qt">{t.title}</span>
          <span class="mono qid">{t.id}</span>
          <button
            :if={t.status == "open"}
            type="button"
            class="cx"
            phx-click="delete_ticket"
            phx-value-id={t.id}
            aria-label={"Delete \"#{t.title}\" from the queue"}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </li>
        <li :for={t <- Enum.take(@closed, 3)} id={"ticket-#{t.id}"} class="qrow closed">
          <span class="qi"><.icon name="hero-check" class="size-3.5" /></span>
          <span class="qt">{t.title}</span>
          <span class="mono qid">{t.id}</span>
        </li>
      </ul>
    </details>
    """
  end

  defp queue_count([], closed), do: "all #{length(closed)} done"
  defp queue_count(open, []), do: "#{length(open)} to do"
  defp queue_count(open, closed), do: "#{length(open)} to do · #{length(closed)} done"

  attr :tab, :map, required: true, doc: "a done chat's tab (`Burrow.Activity.done?/2`)"
  attr :full?, :boolean, required: true, doc: "no room for another chat"
  attr :attach?, :boolean, required: true, doc: "its agent runs, so opencode can attach"

  @doc """
  In place of a done chat's box: its change is out and the chat sits under
  Done in the drawer, so the next change starts in a new chat, maybe
  following up on this one.
  """
  def chat_done(assigns) do
    assigns = assign(assigns, id: assigns.tab.draft.change, day: day(assigns.tab))

    ~H"""
    <section id="chat-done" class="ws-done" aria-label="This chat is done">
      <div class="h">
        <.icon name="hero-check" class="size-[17px] self-center text-[var(--ok)]" />
        <b>#{@id} {if @tab.phase == "live", do: "is live.", else: "is on main."}</b>
        <span>This chat is done and has moved to {@day}.</span>
      </div>
      <div class="a">
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="new_chat"
          disabled={@full?}
          title={@full? && full_text()}
        >
          New chat <kbd>⌃B C</kbd>
        </button>
        <button
          type="button"
          class="btn btn-secondary btn-sm"
          phx-click="follow_up"
          disabled={@full?}
          title={@full? && full_text()}
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
  defp badge("landing", true), do: "on main"
  defp badge("landing", false), do: "on main"
  defp badge("staged", _), do: "on staging"
  defp badge("live", true), do: "live"
  defp badge("live", false), do: "on prod"
  defp badge(_, _), do: "not submitted"

  defp badge_tone(phase) when phase in ~w(working landing), do: "warn"
  defp badge_tone("failed"), do: "err"
  defp badge_tone(phase) when phase in ~w(ready staged live), do: "ok"
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
  attr :live_only?, :boolean, required: true
  attr :dev?, :boolean, required: true
  attr :number, :any, doc: "the chat's change number, once on main"
  attr :chat, :map
  attr :info, :map
  attr :frame_key, :integer, required: true
  attr :show_logs, :boolean, required: true
  attr :logs, :string, required: true
  attr :project, :map
  attr :design, :map, default: nil, doc: "the design view's switch: `%{count, drawing, note}`"
  slot :inner_block, doc: "the design view"

  @doc """
  The version switch and what it shows: the chat's dev preview, staging or
  prod, or its boards (the inner block) in the design view.
  """
  def preview_pane(assigns) do
    ~H"""
    <div class="vbar">
      <div class="seg" role="group" aria-label="Version shown">
        <button
          :for={env <- Enum.reverse(@env_names)}
          type="button"
          phx-click="view"
          phx-value-view={env}
          aria-pressed={to_string(@view == env)}
        >
          {env_label(env, @live_only?)}
        </button>
        <button
          type="button"
          phx-click="view"
          phx-value-view="dev"
          aria-pressed={to_string(@view == "dev")}
          disabled={!@dev?}
          title={
            if !@dev?,
              do:
                "The chat's dev preview starts with its first message, and goes once its change is live"
          }
        >
          {if @number && @dev?, do: "dev ##{@number}", else: "dev"}
        </button>
        <button
          :if={@design}
          id="design-view"
          type="button"
          phx-click="view"
          phx-value-view="design"
          aria-pressed={to_string(@view == "design")}
          data-kb-key="d"
          data-kb-label="Design"
          data-kb-group="Agent & preview"
          title="Boards in design/"
        >
          design<span
            :if={@design.count > 0}
            class="dcnt"
            aria-label={"#{@design.count} boards changed in this chat"}
          >{@design.count}</span><span :if={@design.drawing} class="ddot" aria-hidden="true"></span>
        </button>
      </div>
      <span :if={@view == "design"} class="mono muted text-[12px] truncate">{@design.note}</span>
      <div :if={@view != "design"} class="contents">
        <span :if={@preview.status} class={["st", st_tone(@preview.status)]}>
          <span class="dot"></span>{preview_word(@preview.status)}
        </span>
        <div class="ws-url mono">
          <.icon name="hero-lock-closed" class="size-3.5 shrink-0 muted" />
          <span class="truncate">{@preview.url || "no preview yet"}</span>
        </div>
        <a
          :for={{name, url} <- @preview[:links] || []}
          href={url}
          target="_blank"
          rel="noopener"
          class="tag mono"
          title={"Open #{name} in a new tab"}
        >
          {name} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
        <a
          :if={@preview[:pr]}
          href={@preview.pr}
          target="_blank"
          rel="noopener"
          class="tag mono"
          title="The chat's pull request"
        >
          PR {pr_number(@preview.pr)} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
        <button
          :if={@preview.url && !@preview[:empty]}
          type="button"
          phx-click="reload_preview"
          data-kb-key="r"
          data-kb-label="Reload preview"
          data-kb-group="Agent & preview"
          class="icon-btn"
          aria-label="Reload preview"
        >
          <.icon name="hero-arrow-path" class="size-[17px]" />
        </button>
        <a
          :if={@preview.url && !@preview[:empty]}
          href={@preview.url}
          target="_blank"
          rel="noopener"
          data-kb="row"
          class="icon-btn"
          aria-label={"Open #{view_name(@view, @live_only?, @number)} in a new tab"}
          title={"Open #{view_name(@view, @live_only?, @number)} in a new tab"}
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </a>
        <form
          :if={(@view == "dev" and @chat) && @info}
          id="keep-running-form"
          phx-change="keep_running"
          class="shrink-0"
        >
          <label class="sr-only" for="keep-running">Keep running</label>
          <select
            id="keep-running"
            name="hours"
            class="field keep"
            title="How long the agent and preview stay up without use, e.g. while others test the preview"
          >
            <option :if={Chats.kept_running?(@chat)} value="kept" selected>
              Running until {Calendar.strftime(@chat.keep_until, "%b %-d, %H:%M UTC")}
            </option>
            <option value="">Stops after 30 min idle</option>
            <option value="4">Keep running 4 hours</option>
            <option value="24">Keep running 1 day</option>
            <option value="168">Keep running 7 days</option>
          </select>
        </form>
        <button
          :if={@view == "dev" and @info}
          type="button"
          phx-click="restart_preview"
          data-kb-key="R"
          data-kb-label="Restart preview"
          data-kb-group="Agent & preview"
          class="btn btn-ghost btn-sm"
        >
          Restart
        </button>
        <button
          :if={@preview.url && !@preview[:empty]}
          type="button"
          phx-click="toggle_logs"
          data-kb-key="v"
          data-kb-label="Preview logs"
          data-kb-group="Agent & preview"
          aria-pressed={to_string(@show_logs)}
          class="btn btn-secondary btn-sm"
        >
          <.icon name="hero-command-line" class="size-4" /> Logs
        </button>
      </div>
    </div>

    {if @view == "design", do: render_slot(@inner_block)}
    <div :if={@view != "design"} class="ws-prev-body">
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
    """
  end

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

  attr :block, :any, required: true
  attr :images, :string, default: nil, doc: "where the chat's images are (ChatImageController)"

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

  def block(%{block: {:peon, messages, ack?}} = assigns) do
    drawn =
      for %{role: :tool, text: text} <- messages,
          path <- Burrow.Design.drawn(text),
          uniq: true,
          do: String.replace_prefix(path, "design/", "")

    assigns = assign(assigns, messages: messages, ack?: ack?, drawn: drawn)

    ~H"""
    <div class="say-peon-turn">
      <Layouts.mark size={28} />
      <div class="flex-1 min-w-0 flex flex-col gap-2">
        <div class="text-[13px] font-semibold leading-[18px]">Peon</div>
        <div :if={@ack?} class="say-agent">Zug zug.</div>
        <.message :for={m <- @messages} message={m} />
        <div :if={@drawn != []} class="blink">
          <button type="button" phx-click="view" phx-value-view="design">Open Design</button>
          · {drawn_text(@drawn)}
        </div>
      </div>
    </div>
    """
  end

  defp drawn_text([one]), do: "#{one} is in Design."

  defp drawn_text(names) do
    {init, [last]} = Enum.split(names, -1)
    "#{Enum.join(init, ", ")} and #{last} are in Design."
  end

  attr :message, :map, required: true

  defp message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="say-agent">{String.replace(@message.text, ~r/\A\s*zug zug\.?\s*/i, "")}</div>
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

  # Peon kept the agent going: the next ticket, or what the goal still misses.
  defp message(%{message: %{role: :note}} = assigns) do
    ~H"""
    <div class="evt note" role="note">
      <span class="ln"></span>
      <span class="mono"><.icon name="hero-arrow-path" class="size-3" /> {note_text(@message)}</span>
      <span class="ln"></span>
    </div>
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

  defp note_text(%{kind: "queue", text: text}) do
    case Regex.run(~r/(\d+) unfinished tickets?/, text) do
      [_, "1"] -> "on to the last ticket in the queue"
      [_, n] -> "on to the next ticket, #{n} left in the queue"
      nil -> "on to the next ticket"
    end
  end

  defp note_text(%{text: text}),
    do: text |> String.split("\n", parts: 2) |> hd() |> String.trim_trailing(":")

  @doc "A tool line's name and the rest: `\"edit lib/a.ex\"` -> `{\"edit\", \"lib/a.ex\"}`."
  def split_tool(text) do
    case String.split(text, " ", parts: 2) do
      [name, rest] -> {name, rest}
      [name] -> {name, ""}
    end
  end

  ## Words and tones

  def env_text(%{status: :watching, deploy: %{target: id}}), do: "watching ##{id}"
  def env_text(%{status: :loading, deploy: %{target: id}}), do: "hot-loading ##{id}"
  def env_text(%{status: :booting, deploy: %{target: id}}), do: "starting ##{id}"
  def env_text(%{status: {:crashed, _}}), do: "down"
  def env_text(%{status: status}), do: to_string(status)

  defp st_tone(:running), do: "ok"

  defp st_tone(status) when status in [:starting, :loading, :booting, :watching, :attaching],
    do: "warn"

  defp st_tone(status) when status in [nil, :stopped, :no_pack], do: "idle"
  defp st_tone(_), do: "err"

  defp preview_word({:crashed, _}), do: "stopped"
  defp preview_word(:no_pack), do: "no preview"
  defp preview_word({:pack_error, _}), do: "pack error"
  defp preview_word(status), do: to_string(status)

  defp mb(nil), do: "?"
  defp mb(bytes), do: div(bytes, 1_048_576)
end
