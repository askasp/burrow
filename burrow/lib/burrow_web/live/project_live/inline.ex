defmodule BurrowWeb.ProjectLive.Inline do
  @moduledoc """
  A live-only project on the projects screen: its running app in a viewer
  (live or the open changeset's dev build) and a dock under it with the chat
  to Peon, the changeset's checks, and a composer. Built from the state the
  project's Peon pushes (`Burrow.Inline`); events go to
  `BurrowWeb.ProjectLive.Index`.
  """

  use BurrowWeb, :html

  alias BurrowWeb.Layouts

  @efforts ~w(low medium high)

  def efforts, do: @efforts

  ## What the list row and header say

  @doc "The list row's label and bar: `{label, tone}`, tone working, waiting or live."
  def row_status(state) do
    phase = phase(state)

    cond do
      busy?(state) or phase in ~w(writing checking landing) -> {"working", "working"}
      phase in ~w(ready failed) -> {"waiting on you", "waiting"}
      tip(state) == nil -> {"waiting on you", "waiting"}
      true -> {"live", "live"}
    end
  end

  @doc "The open changeset's number for the row, as \"#9\", or \"—\"."
  def dev_tip(state) do
    case state && state["changeset"] do
      %{"id" => id, "phase" => p} when id != nil and p in ~w(checking failed ready landing) ->
        "##{id}"

      _ ->
        "—"
    end
  end

  def live_tip(state), do: if(tip = tip(state), do: "##{tip}", else: "—")

  @doc "The header's middle part: what the project is doing."
  def detail(nil), do: nil

  def detail(state) do
    cs = state["changeset"] || %{}
    id = cs["id"] && "##{cs["id"]}"

    case cs["phase"] do
      "writing" -> "writing"
      "checking" -> "#{id} · #{current_step(cs)}"
      "failed" -> "#{id} checks failed"
      "ready" -> "#{id} ready to merge"
      "landing" -> "#{id} merging"
      _ -> if(tip = tip(state), do: "live ##{tip}", else: "nothing built yet")
    end
  end

  ## The viewer and the dock

  attr :project, :map, required: true
  attr :state, :map, default: nil
  attr :view, :string, required: true
  attr :frame_key, :integer, required: true
  attr :msg, :string, required: true
  attr :models, :list, required: true
  attr :model, :string, default: nil
  attr :effort, :string, required: true

  def inline(assigns) do
    assigns = assign(assigns, vm: view_model(assigns))

    ~H"""
    <div id="inline" class="flex flex-col gap-3">
      <div class="viewer">
        <div class="vbar">
          <div class="seg" role="group" aria-label="Version shown">
            <button
              type="button"
              aria-pressed={to_string(@vm.view == "live")}
              phx-click="view"
              phx-value-view="live"
            >
              live
            </button>
            <button
              id="view-dev"
              type="button"
              aria-pressed={to_string(@vm.view == "dev")}
              disabled={!@vm.has_dev}
              phx-click="view"
              phx-value-view="dev"
            >
              {@vm.dev_label}
            </button>
          </div>
          <span id="viewer-status" class={["st", @vm.status_tone]}>
            <span class="dot"></span>{@vm.status}
          </span>
          <div class="url mono">
            <.icon name="hero-lock-closed" class="size-3.5" />
            <span class="truncate">{@vm.host}</span>
          </div>
          <button
            type="button"
            class="icon-btn sm"
            aria-label="Reload"
            title="Reload"
            phx-click="reload"
            data-kb-key="r"
            data-kb-label="Reload the app"
            data-kb-group="App"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
          <a
            :if={@vm.url}
            href={@vm.url}
            target="_blank"
            rel="noopener"
            class="icon-btn sm"
            aria-label={@vm.open_label}
            title={@vm.open_label}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </a>
          <button
            :if={!@vm.url}
            type="button"
            class="icon-btn sm"
            aria-label={@vm.open_label}
            disabled
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </button>
        </div>
        <div class="vbody">
          <div :if={@vm.body == :building} class="vcenter" role="status">
            <span class="flex text-[var(--accent-text)]">
              <.icon name="hero-arrow-path" class="size-7 spin" />
            </span>
            <div class="text-base leading-6 font-semibold">{@vm.building_title}</div>
            <div class="mono text-[12.5px] text-[var(--text-3)]">{@vm.building_step}</div>
          </div>
          <div :if={@vm.body == :failed} class="vcenter" role="status">
            <div class="text-base leading-6 font-semibold">Checks failed</div>
            <div class="mono text-[12.5px] text-[var(--err)]">{@vm.building_step}</div>
          </div>
          <div :if={@vm.body == :empty} class="vcenter">
            <div class="text-base leading-6 font-semibold">Nothing here yet</div>
            <div class="mono text-[12.5px] text-[var(--text-3)]">{@vm.host}</div>
          </div>
          <iframe
            :if={@vm.body == :frame}
            id={"app-frame-#{@vm.view}-#{@frame_key}"}
            src={@vm.url}
            title={"#{@project.name}, #{@vm.version}"}
            class="vframe"
          ></iframe>
        </div>
      </div>

      <div class="dock">
        <div :if={@vm.chat} id="thread" class="thread" role="log" aria-label="Chat with Peon">
          <div class="tin">
            <%= for item <- @vm.thread do %>
              <div :if={item.kind == :user} class="bubble-user">{item.text}</div>
              <div :if={item.kind == :note} class="evt">
                <span class="ln"></span><span class="mono">{item.text}</span><span class="ln"></span>
              </div>
              <div :if={item.kind == :peon} class="flex gap-2.5 items-start">
                <Layouts.mark size={24} />
                <div class="flex-1 min-w-0 flex flex-col gap-1.5">
                  <div class="text-[13px] font-semibold leading-[18px]">Peon</div>
                  <%= for part <- item.parts do %>
                    <div :if={part.kind == :tool} class={["tool mono", part.error && "err"]}>
                      <span class="ar">→</span> <span class="nm">{part.name}</span> {part.arg}
                    </div>
                    <div :if={part.kind == :text} class="say">{part.text}</div>
                    <div :if={part.kind == :error} class="say err">{part.text}</div>
                  <% end %>
                  <div :if={item.working} class="wk" role="status">
                    <span class="swing" aria-hidden="true"><.pickaxe size={16} /></span>
                    <span>Peon is working…</span>
                    <span class="mono">{@vm.working_detail}</span>
                  </div>
                </div>
              </div>
            <% end %>
            <div :if={@vm.event} class={["evt", @vm.event_tone]} role="note">
              <span class="ln"></span><span class="mono">{@vm.event}</span><span class="ln"></span>
            </div>
          </div>
        </div>

        <div :if={@vm.cs} id="changeset" class="csbar" role="group" aria-label="Changeset">
          <div class="csrow">
            <span class="flex text-[var(--rust)]"><.branch size={16} /></span>
            <span class="text-sm leading-5 font-semibold">{@vm.cs_label}</span>
            <span class={["st", @vm.cs_tone]}><span class="dot"></span>{@vm.cs_status}</span>
            <div class="flow mono ml-auto">
              <span class="on">{@vm.flow_dev}</span>
              <.icon name="hero-arrow-right" class="size-3" />
              <span class={@vm.main_on && "on"}>main</span>
              <.icon name="hero-arrow-right" class="size-3" />
              <span class={@vm.live_on && "on"}>live</span>
            </div>
          </div>
          <div class="csrow">
            <div class="steps">
              <span :for={step <- @vm.steps} class={["step", step_class(step["status"])]}>
                <span class="i"><.step_icon status={step["status"]} /></span>
                <span class="mono">{step["name"]}</span>
              </span>
            </div>
            <div class="acts">
              <button
                :if={@vm.can_discard}
                id="discard"
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="discard"
                data-kb-key="d"
                data-kb-label="Discard the changeset"
                data-kb-group="App"
              >
                Discard
              </button>
              <button
                :if={@vm.show_merge}
                id="merge"
                type="button"
                class="btn btn-primary btn-sm"
                disabled={!@vm.can_merge}
                phx-click="merge"
                phx-disable-with="Merging…"
                data-kb-key="m"
                data-kb-label="Merge to main"
                data-kb-group="App"
              >
                <.branch size={15} /> Merge to main
              </button>
              <div :if={@vm.landing} class="dep" role="status">
                <span>Going live</span>
                <span class="dbar" aria-hidden="true"><i style={"width: #{@vm.pct}"}></i></span>
              </div>
              <span :if={@vm.live_done} class="live" role="status">
                <.icon name="hero-check" class="size-4" /> Live
              </span>
              <span :if={@vm.deploy_failed} class="st err" role="status">
                <span class="dot"></span>Prod went back to the last version that worked
              </span>
            </div>
          </div>
        </div>

        <.form
          for={%{}}
          as={:msg}
          id="inline-composer"
          class="cmp"
          phx-change="typing"
          phx-submit="send"
        >
          <label class="sr-only" for="inline-msg">Message Peon about {@project.name}</label>
          <input
            id="inline-msg"
            name="text"
            type="text"
            autocomplete="off"
            value={@msg}
            placeholder={@vm.placeholder}
            data-kb-key="i"
            data-kb-label="Ask Peon"
            data-kb-group="App"
          />
          <div class="cbar">
            <div class="selw">
              <label class="sr-only" for="inline-agent">Agent</label>
              <select
                id="inline-agent"
                name="model"
                class="pick"
                disabled={@vm.locked}
                title={@vm.locked && "Set when a chat starts. The next change gets a new chat."}
              >
                <option :for={m <- @vm.models} value={m} selected={m == @vm.model}>
                  {model_label(m)}
                </option>
              </select>
              <.icon name="hero-chevron-down" class="size-3" />
            </div>
            <div class="effort" role="group" aria-label="Effort">
              <span class="k" aria-hidden="true">effort</span>
              <button
                :for={{name, i} <- Enum.with_index(efforts())}
                type="button"
                class={["pip", "p#{i + 1}", i <= @vm.effort_index && "on"]}
                aria-label={"Effort #{name}"}
                aria-pressed={to_string(name == @vm.effort)}
                disabled={@vm.locked}
                phx-click="effort"
                phx-value-effort={name}
              >
                <i></i>
              </button>
              <span class="v" aria-hidden="true">{@vm.effort}</span>
            </div>
            <button
              id="inline-send"
              type="submit"
              class="btn btn-primary send"
              aria-label="Send"
              disabled={@vm.working or String.trim(@msg) == ""}
            >
              <.icon name="hero-arrow-up" class="size-4" />
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp step_icon(assigns) when assigns.status in ["passed", "failed", "running"] do
    ~H"""
    <.icon :if={@status == "passed"} name="hero-check" class="size-3.5" />
    <.icon :if={@status == "failed"} name="hero-x-mark" class="size-3.5" />
    <.icon :if={@status == "running"} name="hero-arrow-path" class="size-3.5 spin" />
    """
  end

  defp step_icon(assigns) do
    ~H"""
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <circle cx="12" cy="12" r="3"></circle>
    </svg>
    """
  end

  defp step_class("passed"), do: "pass"
  defp step_class("failed"), do: "fail"
  defp step_class("running"), do: "run"
  defp step_class(_), do: "wait"

  attr :size, :integer, default: 13

  def pickaxe(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M4 20L16 8"></path>
      <path d="M8 5Q19 5 19 16"></path>
    </svg>
    """
  end

  attr :size, :integer, default: 16

  defp branch(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <circle cx="6" cy="5" r="2"></circle>
      <circle cx="6" cy="19" r="2"></circle>
      <circle cx="18" cy="12" r="2"></circle>
      <path d="M6 7v10"></path>
      <path d="M6 7c0 3 3 5 10 5"></path>
    </svg>
    """
  end

  defp model_label(model), do: model |> String.split("/", parts: 2) |> List.last()

  ## The view model

  @doc "Which version the viewer can show: \"dev\" only while there is a changeset to see."
  def has_dev?(state), do: phase(state) in ~w(writing checking failed ready landing)

  defp view_model(assigns) do
    state = assigns.state || %{}
    live = state["live"] || %{}
    chat = state["chat"]
    cs = state["changeset"]
    phase = cs && cs["phase"]
    id = cs && cs["id"]
    tip = live["tip"]
    has_dev = has_dev?(state)
    view = if assigns.view == "dev" and has_dev, do: "dev", else: "live"
    dev? = view == "dev"
    url = if dev?, do: chat && chat["preview_url"], else: live["url"]
    busy = busy?(state)
    working = busy or phase in ~w(writing checking landing)
    locked = chat != nil and phase not in ~w(landing live deploy_failed)

    {body, status, tone} =
      cond do
        dev? and phase in ~w(writing checking) -> {:building, "building", "warn"}
        dev? and phase == "failed" -> {:failed, "checks failed", "err"}
        (dev? and chat) && chat["preview_status"] == "running" -> {:frame, "running", "ok"}
        dev? -> {:building, "starting", "warn"}
        tip == nil -> {:empty, "not built", "idle"}
        live["status"] == "building" and live["good"] == nil -> {:building, "building", "warn"}
        live["status"] == "building" -> {:frame, "building", "warn"}
        live["status"] == "stopped" -> {:frame, "stopped", "err"}
        true -> {:frame, "running", "ok"}
      end

    model = (chat && chat["model"]) || assigns.model || List.first(assigns.models)
    effort = (locked && chat["effort"]) || assigns.effort
    effort = if effort in @efforts, do: effort, else: "medium"
    version = if dev?, do: dev_label(id, has_dev), else: "live"

    %{
      view: view,
      has_dev: has_dev,
      dev_label: dev_label(id, has_dev),
      flow_dev: if(id, do: "dev ##{id}", else: "dev"),
      version: version,
      url: url,
      host: host(url),
      open_label: "Open #{version} in a new tab",
      status: status,
      status_tone: tone,
      body: body,
      building_title:
        cond do
          not dev? -> "Going live ##{tip}"
          id -> "Building ##{id}"
          true -> "Building"
        end,
      building_step: if(cs, do: current_step(cs), else: ""),
      chat: chat,
      thread: if(chat, do: thread(chat["messages"] || [], busy or phase == "checking"), else: []),
      working_detail: working_detail(cs),
      event: event(phase, id),
      event_tone: if(phase == "live", do: "ok", else: phase == "deploy_failed" && "err"),
      cs: cs,
      cs_label: if(id, do: "Changeset ##{id}", else: "Changeset"),
      cs_status: cs_status(phase),
      cs_tone: cs_tone(phase),
      main_on: phase in ~w(landing live deploy_failed),
      live_on: phase == "live",
      steps: (cs && cs["steps"]) || [],
      can_discard: phase == "ready",
      show_merge: phase in ~w(writing checking failed ready),
      can_merge: phase == "ready",
      landing: phase == "landing",
      pct: pct(cs && cs["deploy"]),
      live_done: phase == "live",
      deploy_failed: phase == "deploy_failed",
      working: working,
      locked: locked,
      models: Enum.uniq(Enum.reject([model | assigns.models], &is_nil/1)),
      model: model,
      effort: effort,
      effort_index: Enum.find_index(@efforts, &(&1 == effort)),
      placeholder:
        if(tip == nil and cs == nil,
          do: "What should #{assigns.project.name} do?",
          else: "Ask Peon to change #{assigns.project.name}"
        )
    }
  end

  defp dev_label(id, true) when id != nil, do: "dev ##{id}"
  defp dev_label(_id, _has_dev), do: "dev"

  defp host(nil), do: "—"

  defp host(url) do
    uri = URI.parse(url)
    default? = {uri.scheme, uri.port} in [{"https", 443}, {"http", 80}]
    "#{uri.host}#{if !default? && uri.port, do: ":#{uri.port}"}/"
  end

  defp cs_status("writing"), do: "writing"
  defp cs_status("checking"), do: "checking"
  defp cs_status("failed"), do: "checks failed"
  defp cs_status("live"), do: "live"
  defp cs_status("deploy_failed"), do: "not live"
  defp cs_status(_), do: "checks passed"

  defp cs_tone(phase) when phase in ~w(writing checking), do: "warn"
  defp cs_tone(phase) when phase in ~w(failed deploy_failed), do: "err"
  defp cs_tone(_), do: "ok"

  defp pct("watching"), do: "80%"
  defp pct(phase) when phase in ["loading", "booting"], do: "45%"
  defp pct(_), do: "10%"

  defp event("landing", id), do: "##{id} merging to main…"
  defp event("live", id), do: "##{id} on main · live"
  defp event("deploy_failed", id), do: "##{id} could not go live"
  defp event(_, _), do: nil

  defp working_detail(%{"id" => id} = cs) when id != nil, do: "##{id} · #{current_step(cs)}"
  defp working_detail(_), do: "writing"

  defp current_step(cs) do
    steps = cs["steps"] || []
    step = Enum.find(steps, &(&1["status"] in ["running", "failed"])) || List.last(steps)
    (step && step["name"]) || "writing"
  end

  # Messages as the dock shows them: your messages as bubbles, Peon's turns
  # (tool calls, text, errors) under its tile, Peon's own notes as a line.
  defp thread(messages, working?) do
    items =
      Enum.reduce(messages, [], fn
        %{"role" => "user", "text" => "[Peon] " <> text}, acc ->
          [%{kind: :note, text: String.slice(text, 0, 120)} | acc]

        %{"role" => "user", "text" => text}, acc ->
          [%{kind: :user, text: text} | acc]

        message, [%{kind: :peon} = turn | acc] ->
          [%{turn | parts: turn.parts ++ [part(message)]} | acc]

        message, acc ->
          [%{kind: :peon, parts: [part(message)], working: false} | acc]
      end)

    items =
      case {working?, items} do
        {false, _} -> items
        {true, [%{kind: :peon} = turn | rest]} -> [%{turn | working: true} | rest]
        {true, _} -> [%{kind: :peon, parts: [], working: true} | items]
      end

    Enum.reverse(items)
  end

  defp part(%{"role" => "tool", "text" => text} = m) do
    [name | arg] = String.split(text, " ", parts: 2)
    %{kind: :tool, name: name, arg: List.first(arg, ""), error: m["status"] == "error"}
  end

  defp part(%{"role" => "error", "text" => text}), do: %{kind: :error, text: text}
  defp part(%{"text" => text}), do: %{kind: :text, text: text}

  defp phase(nil), do: nil
  defp phase(state), do: get_in(state, ["changeset", "phase"])

  defp tip(nil), do: nil
  defp tip(state), do: get_in(state, ["live", "tip"])

  defp busy?(nil), do: false
  defp busy?(state), do: get_in(state, ["chat", "busy"]) == true
end
