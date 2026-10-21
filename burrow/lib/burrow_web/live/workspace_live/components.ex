defmodule BurrowWeb.WorkspaceLive.Components do
  @moduledoc """
  The workspace's parts (`BurrowWeb.WorkspaceLive`): the project rail, the
  project bar, the chat tabs and change card, the preview pane, "Deploys
  and usage", and the dialogs.
  """

  use BurrowWeb, :html

  alias Burrow.Chats

  ## Project rail

  attr :rail, :list, required: true
  attr :open, :boolean, required: true
  attr :theme, :string, required: true

  @doc """
  Every project the user can open, a tile each with a health bar along its
  bottom (`Burrow.Activity`); names show when the rail is open.
  """
  def rail(assigns) do
    ~H"""
    <nav class={["rail", @open && "open"]} aria-label="Projects" data-kb-zoom-hide>
      <div class="rtop">
        <.link class="rlogo" navigate={~p"/projects"} title="All projects" aria-label="All projects">
          <Layouts.mark size={34} /><span class="rword rt">peon</span>
        </.link>
      </div>
      <ul class="rlist">
        <li :for={p <- @rail}>
          <.link
            class="ritem"
            navigate={p.url}
            aria-current={if p.current, do: "page"}
            data-kb-current={if p.current, do: "1"}
            data-kb="item"
            title={"#{p.name} · #{p.label}"}
          >
            <span class="ri" aria-hidden="true">
              {initial(p.name)}<span class={["rhp", p.state]}><i style={"width: #{p.pct}%"}></i></span>
            </span>
            <span class="rn">
              <span class="nm">{p.name}</span>
              <span class={["lbl", p.state]}>
                <span :if={p.state == "working"} class="swing" aria-hidden="true">
                  <.icon name="hero-wrench" class="size-3" />
                </span>{p.label}
              </span>
            </span>
            <span class="sr-only">, {p.label}</span>
          </.link>
        </li>
      </ul>
      <div class="rbot">
        <button
          id="new-project-btn"
          type="button"
          class="rbtn"
          title="New project"
          aria-haspopup="dialog"
          phx-click={
            JS.remove_class("drawer", to: ".ws-root")
            |> JS.push("dialog", value: %{dialog: "new_project"})
          }
          data-kb-key="N"
          data-kb-label="New project"
          data-kb-group="Projects"
        >
          <.icon name="hero-plus" class="size-[18px] shrink-0" /><span class="rt">New project</span>
        </button>
        <.link class="rbtn" navigate={~p"/projects"} title="Projects, teams and AI login">
          <.icon name="hero-squares-2x2" class="size-[18px] shrink-0" /><span class="rt">Account</span>
        </.link>
        <button
          type="button"
          class="rbtn"
          phx-click="theme"
          title={"Theme: #{theme_name(@theme)}. Click for #{theme_name(next_theme(@theme))}."}
          aria-label={"Theme: #{theme_name(@theme)}"}
        >
          <.icon name={theme_icon(@theme)} class="size-[18px] shrink-0" /><span class="rt">{theme_name(
            @theme
          )}</span>
        </button>
        <button
          type="button"
          class="rbtn rcollapse"
          phx-click="toggle_rail"
          aria-expanded={to_string(@open)}
          aria-label={if @open, do: "Collapse projects", else: "Show project names"}
          title={if @open, do: "Collapse projects", else: "Show project names"}
          data-kb-key="b"
          data-kb-label={if @open, do: "Collapse projects", else: "Show project names"}
          data-kb-group="Projects"
        >
          <.icon
            name="hero-chevron-double-right"
            class={["size-[18px] shrink-0 rchev", @open && "rotate-180"]}
          /><span class="rt">Collapse</span>
        </button>
      </div>
    </nav>
    """
  end

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

  ## Project bar

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
  The project's name and versions, \"Deploys and usage\", and the ⋯ menu.
  On phones the menu also holds what the bars show on a wide screen.
  """
  def project_bar(assigns) do
    ~H"""
    <div class="pbar">
      <button
        type="button"
        class="icon-btn pbar-menu"
        aria-label="Projects"
        phx-click={JS.add_class("drawer", to: ".ws-root")}
      >
        <.icon name="hero-bars-3" class="size-5" />
      </button>
      <div class="pbar-title">
        <h1 class="pbar-name">{@project && @project.name}</h1>
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

  ## Chat tabs

  attr :tabs, :list, required: true
  attr :chat, :map
  attr :project, :map
  attr :base, :string, required: true, doc: "the workspace's path"
  attr :nothing_built?, :boolean, required: true
  attr :repo?, :boolean, required: true

  @doc "A tab per chat, with where its change stands; up to `Burrow.Chats.max/0`."
  def chat_tabs(assigns) do
    assigns = assign(assigns, full?: length(assigns.tabs) >= Chats.max())

    ~H"""
    <div class="chead">
      <div class="ctabs" role="tablist" aria-label="Chats">
        <div :for={t <- @tabs} class="tabw" id={"tab-#{t.chat.id}"}>
          <.link
            patch={"#{@base}/c/#{t.chat.id}"}
            class="ctab"
            role="tab"
            aria-selected={to_string(@chat != nil and @chat.id == t.chat.id)}
            data-kb="tab"
            data-kb-current={if(@chat && @chat.id == t.chat.id, do: "1")}
            title={tab_tip(t, @project, @nothing_built?)}
          >
            <span class={["cdot", dot(t.phase)]} aria-hidden="true"></span>
            <span :if={number(t)} class="n">#{number(t)}</span>
            <span class="t">{tab_title(t, @project, @nothing_built?)}</span>
          </.link>
          <button
            :if={closable?(t, @repo?)}
            type="button"
            class="cx"
            phx-click="close_chat"
            phx-value-id={t.chat.id}
            aria-label={"Close #{tab_title(t, @project, @nothing_built?)}"}
            data-confirm={close_confirm(t, @repo?)}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </div>
      <span title={if @full?, do: "Up to #{Chats.max()} chats. Close one first.", else: "New chat"}>
        <button
          id="new-chat"
          type="button"
          class="icon-btn sm"
          aria-label="New chat"
          phx-click="new_chat"
          disabled={@full?}
          data-kb-key="c"
          data-kb-label="New chat"
          data-kb-group="Chats"
          data-kb-focus="#chat-input"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      </span>
    </div>
    """
  end

  defp tab_title(%{chat: %{title: ""}}, project, true),
    do: "What should #{project && project.name} do?"

  defp tab_title(%{chat: %{title: ""}}, _project, _nothing_built?), do: "New chat"
  defp tab_title(%{chat: %{title: title}}, _project, _nothing_built?), do: title

  defp tab_tip(t, project, nothing_built?) do
    number = if number(t), do: "##{number(t)} · ", else: ""
    "#{number}#{tab_title(t, project, nothing_built?)} · #{phase_text(t.phase)}"
  end

  # A chat's change has a number once it is on main.
  defp number(%{draft: %{change: id}}) when id != nil, do: id
  defp number(_tab), do: nil

  defp phase_text("working"), do: "working"
  defp phase_text("failed"), do: "checks failed"
  defp phase_text("ready"), do: "pull request open"
  defp phase_text("landing"), do: "on main"
  defp phase_text("staged"), do: "on staging"
  defp phase_text("live"), do: "live"
  defp phase_text("idle"), do: "nothing submitted yet"
  defp phase_text(_), do: "new"

  defp dot(phase) when phase in ~w(working landing), do: "working"
  defp dot(phase) when phase in ~w(ready staged failed), do: "waiting"
  defp dot("live"), do: "done"
  defp dot(_), do: "new"

  # Shipped (live) chats and chats with nothing submitted close; a repo chat's
  # pull request stays open.
  defp closable?(%{phase: phase}, true), do: phase in ~w(new idle ready)
  defp closable?(%{phase: phase}, false), do: phase in ~w(new idle live)

  defp close_confirm(%{phase: "new"}, _repo?), do: nil

  defp close_confirm(%{phase: "live"}, _repo?),
    do: "Close this chat? What it merged stays; its agent and preview go."

  defp close_confirm(_tab, true),
    do:
      "Close this chat? Its agent, preview and checkout go; a pull request it opened stays open."

  defp close_confirm(_tab, false), do: "Close this chat? The conversation goes with it."

  ## Peon at work

  attr :kind, :string, default: "mine", doc: ~s("mine" or "chop")

  @doc "A tiny peon at work: carrying gold from the mine to the town hall, or chopping lumber."
  def peon_at_work(assigns) do
    ~H"""
    <svg class="wc3" viewBox="0 0 96 20" width="96" height="20" aria-hidden="true">
      <%= if @kind == "chop" do %>
        <g class="logs">
          <rect x="46" y="15" width="13" height="3" rx="1.5" /><rect
            x="4"
            y="12"
            width="10"
            height="3"
            rx="1.5"
          />
        </g>
        <g class="tree">
          <rect class="trunk" x="77" y="11" width="4" height="8" /><polygon
            class="leaf"
            points="79,0 89,13 69,13"
          />
        </g>
        <g transform="translate(66 0)">
          <rect class="body" x="-2" y="10" width="5" height="6" rx="1" />
          <circle class="head" cx="0.5" cy="7.5" r="2.6" />
          <rect class="leg" x="-1.5" y="16" width="1.6" height="3" />
          <rect class="leg r" x="1" y="16" width="1.6" height="3" />
          <g class="axe">
            <line class="haft" x1="2" y1="12" x2="7" y2="6" /><rect
              class="blade"
              x="6"
              y="3.5"
              width="3"
              height="3.5"
            />
          </g>
        </g>
      <% else %>
        <g class="hall">
          <polygon class="roof" points="1,9 10,2 19,9" /><rect
            class="wall"
            x="3"
            y="9"
            width="14"
            height="10"
          />
          <rect class="door" x="8" y="13" width="4" height="6" />
        </g>
        <g class="mine">
          <path class="rock" d="M75 19 Q77 6 85 5 Q94 6 95 19 Z" /><rect
            class="hole"
            x="82"
            y="12"
            width="6"
            height="7"
            rx="2"
          />
          <circle class="gold" cx="79" cy="11" r="1" /><circle class="gold" cx="91" cy="13" r="1" />
        </g>
        <g class="walker">
          <rect class="body" x="-2" y="10" width="5" height="6" rx="1" />
          <circle class="head" cx="0.5" cy="7.5" r="2.6" />
          <circle class="sack" cx="4.5" cy="11" r="2.4" />
          <rect class="leg" x="-1.5" y="16" width="1.6" height="3" />
          <rect class="leg r" x="1" y="16" width="1.6" height="3" />
        </g>
      <% end %>
    </svg>
    """
  end

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

  @doc "The version switch and what it shows: the chat's dev preview, staging or prod."
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
          title={if !@dev?, do: "The chat's dev preview starts with its first message"}
        >
          {if @number && @dev?, do: "dev ##{@number}", else: "dev"}
        </button>
      </div>
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

    <div class="ws-prev-body">
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

  def block(%{block: {:user, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <div class="bubble-user">{@message.text}</div>
    """
  end

  def block(%{block: {:peon, messages, ack?}} = assigns) do
    assigns = assign(assigns, messages: messages, ack?: ack?)

    ~H"""
    <div class="say-peon-turn">
      <Layouts.mark size={28} />
      <div class="flex-1 min-w-0 flex flex-col gap-2">
        <div class="text-[13px] font-semibold leading-[18px]">Peon</div>
        <div :if={@ack?} class="say-agent">Zug zug.</div>
        <.message :for={m <- @messages} message={m} />
      </div>
    </div>
    """
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
