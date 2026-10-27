defmodule BurrowWeb.WorkspaceLive.Horde do
  @moduledoc """
  A horde in its chat (`Burrow.Hordes`), as the Peon UI kit's "The queue,
  run as a crew" boards: the chat's tk queue in waves, ready to run as a
  horde; then a tile per ticket in the thread (blocked ones wait on others,
  and picking one lights up what it waits on and what waits on it); what
  needs the user (main went red, a stuck ticket); the line over the box
  with Pause and Stop; and one ticket looked into, in the preview's place.
  """

  use BurrowWeb, :html

  alias Burrow.Hordes

  # A peon's status: its tile's look, and its name.
  @looks %{
    "queued" => "queue",
    "blocked" => "block",
    "working" => "work",
    "checking" => "check",
    "fixing" => "fix",
    "retrying" => "fix",
    "needs_you" => "need",
    "held" => "held",
    "shipped" => "ship",
    "skipped" => "skip",
    "stopped" => "skip",
    "reverted" => "skip"
  }
  @names %{
    "queued" => "Ready",
    "blocked" => "Blocked",
    "working" => "Working",
    "checking" => "Checking",
    "fixing" => "Fixing",
    "retrying" => "Thinking harder",
    "needs_you" => "Needs you",
    "held" => "Ready, held",
    "shipped" => "Shipped",
    "skipped" => "Skipped",
    "stopped" => "Stopped",
    "reverted" => "Reverted"
  }
  @tones %{
    "working" => "working",
    "checking" => "idle",
    "fixing" => "err",
    "retrying" => "err",
    "needs_you" => "warn",
    "held" => "ok",
    "shipped" => "ok"
  }
  # The bar's order: shipped first, waiting last.
  @order ~w(shipped held working checking fixing retrying needs_you queued blocked skipped stopped reverted)

  @doc "A horde's chat in the drawer: `{text, tone}`."
  def horde_row(horde) do
    summary = Hordes.summary(horde)
    stuck = summary.counts["needs_you"]

    case horde.status do
      "done" ->
        {"Horde done · #{summary.shipped} shipped", "done"}

      "stopped" ->
        {"Horde stopped · #{summary.shipped} shipped", "done"}

      _ ->
        {"Horde · #{summary.shipped}/#{summary.total} shipped" <>
           if(stuck, do: " · #{stuck} need you", else: ""),
         if(stuck || horde.status == "paused", do: "waiting", else: "working")}
    end
  end

  def look(status), do: @looks[status]

  # A queued peon whose tickets haven't all shipped is blocked.
  defp status(horde, %{status: "queued"} = peon),
    do: if(Hordes.ready?(horde, peon), do: "queued", else: "blocked")

  defp status(_horde, peon), do: peon.status

  defp who(%{ticket: nil, n: n}), do: "Peon ##{n}"
  defp who(%{ticket: ticket}), do: ticket

  attr :tickets, :list, required: true, doc: "the chat's open tk tickets (`Burrow.Tickets`)"
  attr :at_once, :integer, required: true
  attr :shipping, :string, required: true, doc: "where a shipped ticket's change goes"

  @doc """
  The chat's tk queue, ready to run as a horde: its tickets by wave (a
  wave starts as what it waits on ships), how many peons at once, and
  Start; or one at a time, or change the tickets first.
  """
  def horde_queue(assigns) do
    peons =
      for {t, n} <- Enum.with_index(assigns.tickets, 1),
          do: %{n: n, ticket: t.id, deps: t.deps, title: t.title, think: think(t.tags)}

    waves = Hordes.waves(%{peons: peons})
    by_wave = peons |> Enum.group_by(&waves[&1.n]) |> Enum.sort()
    assigns = assign(assigns, count: length(peons), by_wave: by_wave)

    ~H"""
    <section id="horde-queue" class="horde" aria-label="Queue">
      <div class="horde-h">
        <span class="t">Queue</span>
        <span class="muted">
          {@count} tk tickets{if length(@by_wave) > 1, do: " · #{length(@by_wave)} waves"}
        </span>
      </div>
      <div :for={{wave, peons} <- @by_wave} class="hwave">
        <div :if={length(@by_wave) > 1} class="hwave-h">
          Wave {wave}<span class="muted">{if wave == 1,
            do: " · starts at once",
            else: " · as what it waits on ships"}</span>
        </div>
        <ol class="htasks">
          <li :for={p <- peons}>
            <span class="mono muted">{p.ticket}</span>
            <span class="min-w-0">
              {p.title}<span :if={p.think} class="think mono">thinks {p.think}</span><span
                :if={p.deps != []}
                class="think mono"
              >after {Enum.join(p.deps, ", ")}</span>
            </span>
          </li>
        </ol>
      </div>
      <div class="horde-meta">
        <span class="atonce">
          Peons at once
          <button
            type="button"
            class="icon-btn"
            aria-label="Fewer at once"
            phx-click="pick_horde"
            phx-value-n={@at_once - 1}
            disabled={@at_once <= 1}
          >
            <.icon name="hero-minus" class="size-4" />
          </button>
          <b>{@at_once}</b>
          <button
            type="button"
            class="icon-btn"
            aria-label="More at once"
            phx-click="pick_horde"
            phx-value-n={@at_once + 1}
            disabled={@at_once >= Hordes.max_at_once()}
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        </span>
        <span>Shipping <span class="acc">{@shipping}</span></span>
        <span>Tickets close as they ship</span>
      </div>
      <div class="horde-acts">
        <button id="horde-start" type="button" class="btn btn-primary" phx-click="horde_start">
          Run as a horde
        </button>
        <button type="button" class="chip fill" phx-click="queue_one_by_one">
          <span>One at a time</span>
        </button>
        <button
          type="button"
          class="chip fill"
          phx-click={JS.focus(to: "#chat-input")}
          title="Tell Peon what to change; it rewrites the tickets"
        >
          <span>Change the tickets</span>
        </button>
      </div>
    </section>
    """
  end

  defp think(tags),
    do: Enum.find_value(tags, fn tag -> with "think:" <> level <- tag, do: level end)

  def name(status), do: @names[status]

  attr :horde, :map, required: true
  attr :selected, :integer, default: nil, doc: "the peon looked into"
  attr :shipping, :string, required: true, doc: "where a shipped peon's change goes"
  attr :main, :integer, default: nil, doc: "main's change that went red"
  attr :errors, :list, default: [], doc: "the errors it paused on (`Burrow.Hordes.errors_of/1`)"

  @doc "The horde at work, what needs the user, and how it ended."
  def horde_card(assigns) do
    horde = assigns.horde
    summary = Hordes.summary(horde)
    statuses = Map.new(horde.peons, &{&1.n, status(horde, &1)})
    counts = Enum.frequencies(Map.values(statuses))
    stuck = Enum.filter(horde.peons, &(&1.status == "needs_you"))
    skipped = Enum.filter(horde.peons, &(&1.status in ~w(skipped stopped)))
    total = max(summary.total, 1)
    error = List.first(assigns.errors)
    selected = assigns.selected && Enum.find(horde.peons, &(&1.n == assigns.selected))
    waves = Hordes.waves(horde)

    assigns =
      assign(assigns,
        summary: summary,
        statuses: statuses,
        stuck: stuck,
        waits: stuck != [] && length(Hordes.waiting(horde, hd(stuck))),
        skipped: skipped,
        deps:
          if(selected,
            do: MapSet.new(Hordes.waits_on(horde, selected), & &1.n),
            else: MapSet.new()
          ),
        waiting:
          if(selected,
            do: MapSet.new(Hordes.waiting(horde, selected), & &1.n),
            else: MapSet.new()
          ),
        waves:
          for(
            {wave, ns} <-
              horde.peons |> Enum.map(& &1.n) |> Enum.group_by(&waves[&1]) |> Enum.sort(),
            map_size(waves) > 0 and Enum.max(Map.values(waves)) > 1,
            do: %{
              wave: wave,
              total: length(ns),
              shipped: Enum.count(ns, &(statuses[&1] == "shipped"))
            }
          ),
        ready: summary.counts["held"] || 0,
        changed: Enum.count(assigns.horde.peons, & &1.change_id),
        error: error,
        culprit:
          error &&
            Enum.find(
              assigns.horde.peons,
              &(&1.status == "shipped" and &1.change_id == error.change_id)
            ),
        bar:
          for(
            status <- @order,
            count = counts[status],
            count != nil,
            do: %{look: @looks[status], pct: count * 100 / total}
          ),
        legend:
          @order
          |> Enum.filter(&counts[&1])
          |> Enum.map(&@looks[&1])
          |> Enum.uniq()
          |> Enum.map(fn look -> {look, legend(look)} end)
      )

    ~H"""
    <section id="horde" class="horde" aria-label="Horde">
      <div class="horde-h">
        <span class="t">Horde</span>
        <span class="muted">
          {@summary.total} {if Enum.any?(@horde.peons, & &1.ticket), do: "tk tickets", else: "peons"} · {@horde.at_once} at a time
        </span>
        <span class="flex-1"></span>
        <span><b>{@summary.shipped}</b><span class="muted">/{@summary.total} shipped</span></span>
      </div>
      <div class="cprog" aria-hidden="true">
        <span :for={b <- @bar} class={"s-#{b.look}"} style={"width: #{b.pct}%"}></span>
      </div>
      <div class="tiles" role="group" aria-label="Peons. Pick one to look inside">
        <button
          :for={p <- @horde.peons}
          id={"peon-#{p.n}"}
          type="button"
          class={[
            "tile",
            "s-#{look(@statuses[p.n])}",
            @selected == p.n && "sel",
            MapSet.member?(@deps, p.n) && "dep",
            MapSet.member?(@waiting, p.n) && "waits"
          ]}
          aria-label={"#{who(p)}, #{p.title}: #{name(@statuses[p.n])}"}
          title={"#{who(p)} #{p.title}" <> if(p.effort, do: " · thinks #{p.effort}", else: "")}
          phx-click="peon"
          phx-value-n={p.n}
        ></button>
      </div>
      <div class="legend">
        <span :for={{look, text} <- @legend}><span class={"mt s-#{look}"}></span>{text}</span>
        <button
          :if={@changed > 0 and @horde.status in ~w(running paused)}
          type="button"
          class="lnk ml-auto"
          phx-click="horde_changes"
        >
          See the changes
        </button>
      </div>
      <div :if={@waves != []} class="hwaves">
        <span :for={w <- @waves} class={["hw", w.shipped == w.total && "ok"]}>
          Wave {w.wave} <b>{w.shipped}/{w.total}</b>
        </span>
      </div>
      <div :if={@ready > 0} id="horde-ready" class="readyrow">
        <span class="mt s-held"></span>
        <span class="flex-1">{@ready} ready to merge: their checks passed.</span>
        <button type="button" class="btn btn-primary btn-sm" phx-click="horde_merge_all">
          Merge {if @ready == 1, do: "it", else: "all #{@ready}"}
        </button>
      </div>
    </section>

    <div :if={@horde.paused_by == "main"} id="horde-red" class="calert red" role="alert">
      <span class="ah"><.icon name="hero-exclamation-triangle" class="size-4" /> Main went red</span>
      <p>
        Main{if @main, do: " ##{@main}"} did not pass in prod mode. The horde paused itself, so
        nothing else merges; peons keep working. The newest change comes out again and its peon fixes it.
      </p>
      <div class="horde-acts">
        <button type="button" class="chip fill" phx-click="horde_resume">
          <span>Resume anyway</span>
        </button>
      </div>
    </div>

    <div :if={@horde.paused_by == "errors"} id="horde-errors" class="calert red" role="alert">
      <span class="ah">
        <.icon name="hero-exclamation-triangle" class="size-4" /> Errors after a ship
      </span>
      <p :if={@error}>
        {String.capitalize(@error.env)} reports “{@error.title}”{if @error.count > 1,
          do: " (#{@error.count} times)"} since #{@error.change_id} went there. The horde paused itself, so
        nothing else merges; peons keep working. {if @error.status == "fixing",
          do: "The auto-fixer works on it in a chat of its own.",
          else: "Nobody fixes it yet."}
      </p>
      <p :if={!@error}>The errors are fixed; the horde goes on as soon as you resume it.</p>
      <div class="horde-acts">
        <.link
          :if={@error && @error.chat_id}
          patch={~p"/projects/#{@horde.project_id}/c/#{@error.chat_id}"}
          class="chip fill"
        >
          <span>Look at the fix</span>
        </.link>
        <button
          :if={@culprit}
          type="button"
          class="chip fill"
          phx-click="horde_revert"
          phx-value-n={@culprit.n}
          data-confirm={"Take ##{@culprit.change_id} out of main again?"}
        >
          <span>Revert #{@culprit.change_id} now</span>
        </button>
        <button type="button" class="chip fill" phx-click="horde_resume">
          <span>Resume anyway</span>
        </button>
      </div>
    </div>

    <div :if={@stuck != []} id="horde-stuck" class="calert need">
      <span class="ah"><span class="mt s-need"></span> Needs you</span>
      <p>
        <%= if length(@stuck) == 1 do %>
          {who(hd(@stuck))} <b>{hd(@stuck).title}</b> is stuck.
        <% else %>
          {length(@stuck)} tickets are stuck.
        <% end %>
        {if @waits > 0,
          do: "#{@waits} wait on it; everything else keeps going.",
          else: "The rest of the horde keeps going."}
      </p>
      <div>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="peon"
          phx-value-n={hd(@stuck).n}
        >
          Help it
        </button>
      </div>
    </div>

    <section :if={@horde.status == "done"} id="horde-done" class="horde">
      <span class="ah ok"><.icon name="hero-check-circle" class="size-4" /> Horde done</span>
      <div class="big">{@summary.shipped} shipped in {took(@horde)}</div>
      <div class="muted">
        {if Enum.any?(@horde.peons, & &1.ticket),
          do: "Every ticket it shipped is closed in tk.",
          else: ""}
        {if @skipped != [], do: "#{length(@skipped)} skipped and left open."}
      </div>
      <div :for={p <- @skipped} class="skiprow">
        <span class="mt s-skip"></span>
        <span class="flex-1 min-w-0 truncate">{who(p)} {p.title}</span>
        <.link :if={p.chat_id} patch={chat_path(@horde, p)} class="chip fill">
          <span>Open its chat</span>
        </.link>
      </div>
      <div :if={@summary.shipped > 0} class="horde-acts">
        <button type="button" class="chip fill" phx-click="horde_changes">
          <span>See all changes</span>
        </button>
        <button
          type="button"
          class="chip fill"
          phx-click="horde_revert_all"
          data-confirm={"Take all #{@summary.shipped} shipped changes out of main again?"}
        >
          <span>Revert the whole horde</span>
        </button>
      </div>
    </section>

    <section :if={@horde.status == "stopped"} id="horde-stopped" class="horde">
      <span class="t">Horde stopped</span>
      <span class="muted">
        {@summary.sub}. Unfinished peons were stopped and their chats kept; their tickets stay open in tk, so you can run the queue again later.
      </span>
      <div :if={@changed > 0} class="horde-acts">
        <button type="button" class="chip fill" phx-click="horde_changes">
          <span>See all changes</span>
        </button>
      </div>
    </section>
    """
  end

  defp legend("ship"), do: "shipped"
  defp legend("held"), do: "ready, held"
  defp legend("work"), do: "working"
  defp legend("check"), do: "checking"
  defp legend("fix"), do: "fixing"
  defp legend("need"), do: "needs you"
  defp legend("queue"), do: "ready"
  defp legend("block"), do: "blocked"
  defp legend("skip"), do: "skipped or stopped"

  defp took(%{started_at: started, finished_at: finished}) when started != nil do
    case div(DateTime.diff(finished || DateTime.utc_now(), started), 60) do
      0 -> "under a minute"
      1 -> "1 min"
      min -> "#{min} min"
    end
  end

  defp took(_horde), do: "no time"

  defp chat_path(horde, peon), do: ~p"/projects/#{horde.project_id}/c/#{peon.chat_id}"

  attr :horde, :map, required: true
  attr :peons, :list, required: true

  # Tickets next to the one looked into: what it waits on, what waits on it.
  defp ticket_rows(assigns) do
    ~H"""
    <div class="trows">
      <button
        :for={p <- @peons}
        type="button"
        class="trow"
        phx-click="peon"
        phx-value-n={p.n}
      >
        <span class={"mt s-#{look(status(@horde, p))}"}></span>
        <span class="mono muted">{who(p)}</span>
        <span class="flex-1 min-w-0 truncate">{p.title}</span>
        <span class="muted">{name(status(@horde, p))}</span>
      </button>
    </div>
    """
  end

  attr :horde, :map, required: true

  @doc "Over the box while the horde runs: how it stands, Pause or Resume, and Stop."
  def horde_bar(assigns) do
    assigns = assign(assigns, summary: Hordes.summary(assigns.horde))

    ~H"""
    <div id="horde-bar" class="horde-bar" role="status">
      <span class={["st", @summary.tone]}><span class="dot"></span></span>
      <span class="ctext"><b>{@summary.text}</b> · {@summary.sub}</span>
      <button
        :if={@horde.status == "running"}
        type="button"
        class="chip fill"
        phx-click="horde_pause"
      >
        <.icon name="hero-pause-solid" class="size-3.5" /><span>Pause</span>
      </button>
      <button
        :if={@horde.status == "paused"}
        type="button"
        class="chip fill"
        phx-click="horde_resume"
      >
        <.icon name="hero-play-solid" class="size-3.5" /><span>Resume</span>
      </button>
      <button
        id="horde-stop"
        type="button"
        class="icon-btn"
        aria-label="Stop the horde"
        title="Stop the horde"
        phx-click="dialog"
        phx-value-dialog="stop_horde"
      >
        <.icon name="hero-stop" class="size-4" />
      </button>
    </div>
    """
  end

  attr :horde, :map, required: true

  @doc "Stop the horde: keep what shipped, or take it out again."
  def stop_dialog(assigns) do
    summary = Hordes.summary(assigns.horde)
    assigns = assign(assigns, shipped: summary.shipped, left: summary.total - summary.shipped)

    ~H"""
    <.modal id="stop-horde" title="Stop the horde?" return_to="horde-stop">
      <p class="m-0 text-[var(--text-2)]">
        {@left} haven’t shipped yet. Their peons stop and keep their chats, and their tickets stay open in tk. The {@shipped} that shipped stay shipped unless you revert them.
      </p>
      <div class="flex flex-col gap-2">
        <button type="button" class="btn btn-secondary" phx-click="horde_stop">
          Stop, keep what shipped
        </button>
        <button
          :if={@shipped > 0}
          type="button"
          class="btn btn-secondary text-[var(--err)]"
          phx-click="horde_stop"
          phx-value-revert="true"
        >
          Stop and revert all {@shipped}
        </button>
        <button type="button" class="btn btn-ghost" phx-click="close_dialog">Keep going</button>
      </div>
    </.modal>
    """
  end

  attr :horde, :map, required: true
  attr :peon, :map, required: true
  attr :failure, :string, default: nil, doc: "its last failed check's output"
  attr :models, :map, default: %{}, doc: "provider/model => its thinking levels"
  attr :model, :any, default: nil, doc: "its chat's `{model, thinking level}`"
  attr :review, :boolean, default: false, doc: "its chat ships for review"

  @doc "One peon, in the preview's place: where it stands, what to do, what it did."
  def peon_detail(assigns) do
    peons = assigns.horde.peons
    i = Enum.find_index(peons, &(&1.n == assigns.peon.n))

    # A bigger model: the same one thinking hardest, until the user picks another.
    {model, _effort} = assigns.model || {nil, nil}
    model = model || assigns.models |> Map.keys() |> List.first()
    efforts = Map.get(assigns.models, model, [])

    assigns =
      assign(assigns,
        prev: i > 0 && Enum.at(peons, i - 1),
        next: Enum.at(peons, i + 1),
        tone: @tones[assigns.peon.status] || "idle",
        status: status(assigns.horde, assigns.peon),
        waits_on: Hordes.waits_on(assigns.horde, assigns.peon),
        waiting: Hordes.waiting(assigns.horde, assigns.peon),
        pick: model,
        efforts: efforts,
        hardest: List.last(efforts),
        groups:
          assigns.models
          |> Map.keys()
          |> Enum.concat(List.wrap(model))
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.chunk_by(&(&1 |> String.split("/") |> hd()))
      )

    ~H"""
    <div id="peon-detail" class="ov pdet">
      <div class="ov-in">
        <div class="pdet-h">
          <button type="button" class="chip" phx-click="peon_close">
            <.icon name="hero-arrow-left" class="size-4" /><span>Horde</span>
          </button>
          <span class="flex-1"></span>
          <button
            type="button"
            class="icon-btn"
            aria-label="Previous peon"
            disabled={!@prev}
            phx-click="peon"
            phx-value-n={@prev && @prev.n}
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </button>
          <button
            type="button"
            class="icon-btn"
            aria-label="Next peon"
            disabled={!@next}
            phx-click="peon"
            phx-value-n={@next && @next.n}
          >
            <.icon name="hero-chevron-right" class="size-5" />
          </button>
        </div>

        <div class="pdet-t">
          <span class="flex items-center gap-2.5">
            <h2 class="m-0 text-lg font-semibold">{who(@peon)}</h2>
            <span class={["st", @tone]}><span class={"mt s-#{look(@status)}"}></span>{name(@status)}</span>
          </span>
          <span class="truncate">{@peon.title}</span>
          <span :if={@peon.effort} class="mono">thinks {@peon.effort}</span>
        </div>

        <div :if={@peon.status == "needs_you"} class="calert need">
          <span class="ah">
            {if @peon.fails >= Hordes.max_fails(),
              do: "Stuck after #{@peon.fails} tries",
              else: "Stopped without shipping"}
          </span>
          <pre :if={@failure} class="out mono">{@failure}</pre>
          <.form for={%{}} as={:hint} id="hint-form" phx-submit="peon_retry" class="hintf">
            <label for="peon-hint" class="h">Give it a hint and retry</label>
            <div class="hintrow">
              <input
                id="peon-hint"
                name="hint"
                type="text"
                class="field"
                placeholder="e.g. Default statuses to [] at the call site"
                autocomplete="off"
              />
              <button type="submit" class="icon-btn go-send" aria-label="Retry with this hint">
                <.icon name="hero-arrow-up" class="size-4" />
              </button>
            </div>
          </.form>
          <details :if={@pick} class="bigger">
            <summary class="chip fill"><span>Retry with a bigger model</span></summary>
            <.form for={%{}} as={:bigger} id="bigger-form" phx-submit="peon_retry" class="hintrow">
              <label class="sr-only" for="bigger-model">Model</label>
              <select id="bigger-model" name="model" class="field pick">
                <optgroup :for={group <- @groups} label={group |> hd() |> String.split("/") |> hd()}>
                  <option :for={m <- group} value={m} selected={m == @pick}>
                    {m |> String.split("/", parts: 2) |> List.last()}
                  </option>
                </optgroup>
              </select>
              <label :if={@efforts != []} class="sr-only" for="bigger-effort">Thinking</label>
              <select :if={@efforts != []} id="bigger-effort" name="effort" class="field pick">
                <option value="">thinking: default</option>
                <option :for={e <- @efforts} value={e} selected={e == @hardest}>thinking: {e}</option>
              </select>
              <button type="submit" class="btn btn-primary btn-sm">Retry</button>
            </.form>
          </details>
          <div class="horde-acts">
            <button type="button" class="chip fill" phx-click="peon_retry">
              <span>Retry as is</span>
            </button>
            <.link patch={chat_path(@horde, @peon)} class="chip fill">
              <.icon name="hero-chat-bubble-left" class="size-4" /><span>Take over in its chat</span>
            </.link>
            <button type="button" class="chip fill" phx-click="peon_skip">
              <span>{if @waiting != [], do: "Skip, let what waits go ahead", else: "Skip it"}</span>
            </button>
            <button
              :if={@waiting != []}
              type="button"
              class="chip fill"
              phx-click="peon_skip"
              phx-value-waiting="true"
            >
              <span>Skip it and the {length(@waiting)} that wait on it</span>
            </button>
          </div>
        </div>

        <div :if={@peon.status == "held"} class="calert">
          <span>
            {if @review,
              do: "Checks passed. It waits for you to merge it.",
              else: "Checks passed. It merges as soon as shipping resumes."}
          </span>
          <div>
            <button
              type="button"
              class={["btn btn-sm", if(@review, do: "btn-primary", else: "btn-secondary")]}
              phx-click="peon_ship"
            >
              {if @review, do: "Merge it", else: "Ship it now anyway"}
            </button>
          </div>
        </div>

        <div :if={@status == "queued"} class="muted">
          Ready. Waiting for a free slot, {@horde.at_once} peons work at once.
        </div>
        <div :if={@status == "blocked"} class="muted">
          Blocked. A peon picks it up as soon as everything it waits on has shipped.
        </div>

        <div :if={@peon.status != "needs_you" and @peon.chat_id} class="horde-acts">
          <.link patch={chat_path(@horde, @peon)} class="chip fill">
            <.icon name="hero-chat-bubble-left" class="size-4" /><span>Open its chat</span>
          </.link>
          <button
            :if={@peon.status in ~w(working checking fixing)}
            type="button"
            class="chip fill"
            phx-click="peon_skip"
          >
            <span>Stop this peon</span>
          </button>
          <button
            :if={@peon.status in ~w(skipped stopped reverted)}
            type="button"
            class="chip fill"
            phx-click="peon_retry"
          >
            <.icon name="hero-arrow-path" class="size-4" /><span>Retry it</span>
          </button>
          <button
            :if={@peon.status == "shipped" and @peon.change_id}
            type="button"
            class="chip fill"
            phx-click="peon_revert"
            data-confirm={"Take ##{@peon.change_id} out of main again?"}
          >
            <span>Revert #{@peon.change_id}</span>
          </button>
        </div>

        <div>
          <div class="h">Its task</div>
          <p class="ptask">{@peon.task}</p>
        </div>

        <div :if={@waits_on != []}>
          <div class="h">Waits on</div>
          <.ticket_rows horde={@horde} peons={@waits_on} />
        </div>

        <div :if={@waiting != []}>
          <div class="h">{length(@waiting)} wait on it</div>
          <.ticket_rows horde={@horde} peons={@waiting} />
        </div>

        <div :if={@peon.log != []}>
          <div class="h">What it did</div>
          <div class="plog">
            <div :for={line <- @peon.log} class="lg">
              <span class="mono muted">{since(@horde, line["at"])}</span>
              <span class={["ldot", line["tone"]]}></span>
              <span>{line["text"]}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :horde, :map, required: true
  attr :changes, :list, required: true, doc: "`Burrow.Hordes.changes/2`"

  @doc "Everything the horde shipped, in the preview's place: each change, its files and diffs."
  def horde_changes(assigns) do
    ~H"""
    <div id="horde-changes" class="ov pdet">
      <div class="ov-in">
        <div class="pdet-h">
          <button type="button" class="chip" phx-click="horde_changes_close">
            <.icon name="hero-arrow-left" class="size-4" /><span>Horde</span>
          </button>
        </div>
        <h2 class="m-0 text-lg font-semibold">
          {length(@changes)} {if length(@changes) == 1, do: "change", else: "changes"} from the horde
        </h2>
        <p :if={@changes == []} class="muted m-0">Nothing shipped yet.</p>
        <section :for={c <- @changes} class="cchange" aria-label={"Change ##{c.change.id}"}>
          <div class="cch">
            <span class="mono">#{c.change.id}</span>
            <span class="flex-1 min-w-0">{c.change.intent}</span>
            <span class={["st", if(c.peon.status == "reverted", do: "idle", else: "ok")]}>
              <span class={"mt s-#{look(c.peon.status)}"}></span>{name(c.peon.status)}
            </span>
          </div>
          <div class="muted text-[12.5px]">Peon #{c.peon.n} · {c.peon.title}</div>
          <details :for={f <- c.files} class="cfile">
            <summary>
              <span class="mono truncate">{f.path}</span>
              <span class="mono add">+{count(f.diff, "+")}</span>
              <span class="mono del">-{count(f.diff, "-")}</span>
            </summary>
            <pre class="diff mono"><span
                :for={line <- String.split(f.diff, "\n")}
                class={diff_class(line)}
              >{line}{"\n"}</span></pre>
          </details>
        </section>
      </div>
    </div>
    """
  end

  defp count(diff, sign),
    do: diff |> String.split("\n") |> Enum.count(&String.starts_with?(&1, sign))

  defp diff_class("+" <> _), do: "add"
  defp diff_class("-" <> _), do: "del"
  defp diff_class(_line), do: nil

  # When, in minutes since the horde started.
  defp since(%{started_at: started}, iso) when started != nil do
    case DateTime.from_iso8601(iso || "") do
      {:ok, at, _} -> "#{max(div(DateTime.diff(at, started), 60), 0)}m"
      _ -> ""
    end
  end

  defp since(_horde, _iso), do: ""
end
