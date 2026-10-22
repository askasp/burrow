defmodule BurrowWeb.WorkspaceLive.Design do
  @moduledoc """
  The preview's Design view (`BurrowWeb.WorkspaceLive`), as the Peon UI
  kit's "8 · Design view" boards: the chat's boards (`Burrow.Design`) in a
  grid by folder, one board full size (or next to the dev preview), the
  peon at its easel while it draws, and the card that lands boards alone.

  Boards are framed from `BurrowWeb.DesignController`, sandboxed. A board's
  script errors come back through the `.BoardErrors` hook as
  `"board_error"`.
  """

  use BurrowWeb, :html

  attr :boards, :list, required: true, doc: "`Burrow.Design.boards/2`"
  attr :open, :string, default: nil, doc: "the board shown full size"
  attr :side, :boolean, required: true, doc: "the open board next to the dev preview"
  attr :drawing, :string, default: nil, doc: "the board the agent draws now"
  attr :errors, :map, required: true, doc: "path => {hash, error}"
  attr :url, :string, required: true, doc: "where the chat's design/ is served"
  attr :dev, :map, default: nil, doc: "the dev preview, when it runs: `%{url, name}`"

  @doc "The boards: a grid, one full size, or none yet."
  def design_pane(assigns) do
    boards = shown(assigns.boards, assigns.drawing)
    open = assigns.open && Enum.find(boards, &(&1.path == assigns.open and &1.hash))

    assigns = assign(assigns, boards: boards, board: open)

    ~H"""
    <div id="design" class="dpane" phx-hook=".BoardErrors">
      <.empty :if={@boards == []} />
      <.grid
        :if={@boards != [] and !@board}
        boards={@boards}
        drawing={@drawing}
        errors={@errors}
        url={@url}
      />
      <.full
        :if={@board}
        board={@board}
        siblings={siblings(@boards, @board)}
        side={@side}
        dev={@dev}
        errors={@errors}
        url={@url}
      />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardErrors">
      // A board posts its script errors to its parent; the frame it came
      // from says which board.
      export default {
        mounted() {
          this.onMessage = (e) => {
            if (!e.data || e.data.board !== "error") return
            const frame = [...this.el.querySelectorAll("iframe[data-path]")].find((f) => f.contentWindow === e.source)
            if (frame) this.pushEvent("board_error", {path: frame.dataset.path, hash: frame.dataset.hash, error: String(e.data.error).slice(0, 300)})
          }
          window.addEventListener("message", this.onMessage)
        },
        destroyed() { window.removeEventListener("message", this.onMessage) }
      }
    </script>
    """
  end

  # A board being drawn is in the grid before its file is.
  defp shown(boards, nil), do: boards

  defp shown(boards, drawing) do
    if Enum.any?(boards, &(&1.path == drawing)) or Path.extname(drawing) not in ~w(.html .htm) do
      boards
    else
      rel = String.replace_prefix(drawing, "design/", "")
      folder = if Path.dirname(rel) == ".", do: "", else: Path.dirname(rel) <> "/"

      new = %{
        path: drawing,
        folder: folder,
        name: Path.basename(rel),
        title: "",
        hash: nil,
        here?: true
      }

      Enum.sort_by([new | boards], &{&1.folder, &1.name})
    end
  end

  defp failed(errors, board) do
    case errors[board.path] do
      {hash, error} when hash == board.hash -> error
      _ -> nil
    end
  end

  defp siblings(boards, board), do: Enum.filter(boards, &(&1.folder == board.folder and &1.hash))

  @doc "A board's URL in the chat's served design/; its hash makes a changed board load again."
  def src(url, board),
    do:
      "#{url}/#{String.replace_prefix(board.path, "design/", "")}?v=#{String.slice(board.hash, 0, 12)}"

  defp empty(assigns) do
    ~H"""
    <div class="dempty">
      <.easel id="easel-idle" idle />
      <h2>No boards in this chat yet</h2>
      <p>
        Ask Peon to draw something. Boards are HTML files in <span class="mono">design/</span>, next to the code.
      </p>
      <div class="chips">
        <button
          :for={ask <- ["Draw 3 takes on the home page", "Sketch an empty state for the main list"]}
          type="button"
          class="chipq"
          phx-click="ask"
          phx-value-text={ask}
        >
          {ask}
        </button>
      </div>
    </div>
    """
  end

  defp grid(assigns) do
    ~H"""
    <div class="dhead">
      <span class="mono">design/</span>
      <span class="muted">{grid_note(@drawing)}</span>
    </div>
    <section
      :for={group <- Enum.chunk_by(@boards, & &1.folder)}
      class="dgroup"
      aria-label={folder_name(hd(group).folder)}
    >
      <div class="gname mono">
        <.icon name="hero-folder" class="size-3.5" />{folder_name(hd(group).folder)}
        <span :if={hd(group).folder != ""} class="muted">{variants(length(group))}</span>
      </div>
      <div class="thumbs">
        <.thumb
          :for={b <- group}
          board={b}
          url={@url}
          busy={b.path == @drawing}
          error={failed(@errors, b)}
        />
      </div>
    </section>
    """
  end

  defp grid_note(nil), do: "main's boards with this chat's changes"

  defp grid_note(drawing),
    do: "main's boards with this chat's changes · Peon is drawing #{Path.basename(drawing)}"

  defp folder_name(""), do: "Loose boards"
  defp folder_name(folder), do: folder

  defp variants(1), do: "1 variant"
  defp variants(n), do: "#{n} variants"

  attr :board, :map, required: true
  attr :url, :string, required: true
  attr :busy, :boolean, required: true
  attr :error, :string, default: nil

  defp thumb(assigns) do
    ~H"""
    <div class={["thumb", @busy && "busy", @error && "bad"]}>
      <div class="tframe">
        <iframe
          :if={@board.hash && !@error}
          id={"thumb-#{@board.hash}"}
          src={src(@url, @board)}
          sandbox="allow-scripts"
          referrerpolicy="no-referrer"
          loading="lazy"
          tabindex="-1"
          aria-hidden="true"
          data-path={@board.path}
          data-hash={@board.hash}
        ></iframe>
        <div :if={@busy} class="over">
          <div class="shim"></div>
          <.easel id={"easel-#{@board.path}"} />
          <span>Peon is drawing…</span>
        </div>
        <div :if={@error} class="errbox">
          <span class="font-semibold">This board didn't load</span>
          <span class="mono err">{@error}</span>
          <span>
            <button
              type="button"
              class="btn btn-secondary btn-sm"
              phx-click="fix_board"
              phx-value-path={@board.path}
            >
              Ask Peon to fix it
            </button>
          </span>
        </div>
        <button
          :if={@board.hash && !@busy && !@error}
          type="button"
          class="hit"
          phx-click="open_board"
          phx-value-path={@board.path}
          aria-label={"Open #{@board.path}"}
        ></button>
      </div>
      <div class="cap">
        <span class="f mono">{@board.name}</span>
        <span class="v">{@board.title}</span>
        <span class={["btag", tag(@board, @busy, @error)]}>{tag_text(@board, @busy, @error)}</span>
      </div>
    </div>
    """
  end

  defp tag(_board, true, _error), do: "busy"
  defp tag(_board, _busy, error) when is_binary(error), do: "bad"
  defp tag(%{here?: true}, _busy, _error), do: "here"
  defp tag(_board, _busy, _error), do: "main"

  defp tag_text(_board, true, _error), do: "drawing"
  defp tag_text(_board, _busy, error) when is_binary(error), do: "didn't load"
  defp tag_text(%{here?: true}, _busy, _error), do: "this chat"
  defp tag_text(_board, _busy, _error), do: "main"

  defp full(assigns) do
    i = Enum.find_index(assigns.siblings, &(&1.path == assigns.board.path))
    assigns = assign(assigns, i: i, error: failed(assigns.errors, assigns.board))

    ~H"""
    <div class="fullbar">
      <button
        type="button"
        class="btn btn-ghost btn-sm"
        phx-click="close_board"
        data-kb-esc
        title="Back to boards (Esc)"
      >
        ← Boards
      </button>
      <span :if={@board.folder != ""} class="mono muted text-[12.5px]">{@board.folder}</span>
      <span class="text-sm font-semibold truncate">{@board.title |> blank_to(@board.name)}</span>
      <span class="pager">
        <button
          type="button"
          class="icon-btn sm"
          aria-label="Previous board"
          title="Previous board (←)"
          disabled={@i == 0}
          phx-click="board_step"
          phx-value-by="-1"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>
        <span class="mono muted text-xs">{@i + 1} of {length(@siblings)}</span>
        <button
          type="button"
          class="icon-btn sm"
          aria-label="Next board"
          title="Next board (→)"
          disabled={@i == length(@siblings) - 1}
          phx-click="board_step"
          phx-value-by="1"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </span>
      <span class="ml-auto flex items-center gap-1.5">
        <button
          :if={@dev}
          type="button"
          class="btn btn-secondary btn-sm"
          aria-pressed={to_string(@side)}
          phx-click="toggle_side"
        >
          Next to {@dev.name}
        </button>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="build_board"
          phx-value-path={@board.path}
          title={"Puts “Build #{@board.path}” in the chat box"}
        >
          Build this
        </button>
        <a
          href={src(@url, @board)}
          target="_blank"
          rel="noopener noreferrer"
          class="icon-btn"
          aria-label="Open in a new tab"
          title="Open in a new tab"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </a>
      </span>
    </div>
    <div
      :if={!(@side and @dev)}
      id="board-full"
      class="fullwrap"
      tabindex="0"
      phx-keydown="board_key"
      aria-label={@board.path}
    >
      <div :if={@error} class="errline">
        <span class="font-semibold">This board didn't load:</span>
        <span class="mono">{@error}</span>
        <button
          type="button"
          class="btn btn-secondary btn-sm"
          phx-click="fix_board"
          phx-value-path={@board.path}
        >
          Ask Peon to fix it
        </button>
      </div>
      <.fit id="fit-board">
        <iframe
          id={"full-#{@board.hash}"}
          src={src(@url, @board)}
          sandbox="allow-scripts allow-forms allow-popups"
          referrerpolicy="no-referrer"
          title={@board.path}
          data-path={@board.path}
          data-hash={@board.hash}
        ></iframe>
      </.fit>
      <div class="mono muted fcap">{@board.path} · 1280 × 800</div>
    </div>
    <div :if={@side and @dev} class="fullwrap">
      <div class="side">
        <div>
          <div class="lab">
            <span class="btag main">board</span><span class="mono">{@board.path}</span>
          </div>
          <.fit id="fit-side-board">
            <iframe
              id={"side-#{@board.hash}"}
              src={src(@url, @board)}
              sandbox="allow-scripts allow-forms allow-popups"
              referrerpolicy="no-referrer"
              title={@board.path}
              data-path={@board.path}
              data-hash={@board.hash}
            ></iframe>
          </.fit>
        </div>
        <div>
          <div class="lab">
            <span class="btag here">{@dev.name}</span><span class="mono truncate">{@dev.url}</span>
          </div>
          <.fit id="fit-side-dev">
            <iframe id="side-dev" src={@dev.url} title={@dev.name}></iframe>
          </.fit>
        </div>
      </div>
      <p class="sidenote">
        Left is the board Peon drew, right is what it built. Spot a gap? Say it in the chat.
      </p>
    </div>
    """
  end

  defp blank_to("", other), do: other
  defp blank_to(text, _other), do: text

  attr :id, :string, required: true
  slot :inner_block, required: true

  # A 1280 × 800 frame scaled to the width it has.
  defp fit(assigns) do
    ~H"""
    <div id={@id} class="fit" phx-hook=".Fit">{render_slot(@inner_block)}</div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Fit">
      export default {
        mounted() {
          this.ro = new ResizeObserver(() => this.fit())
          this.ro.observe(this.el)
          this.fit()
        },
        updated() { this.fit() },
        destroyed() { this.ro.disconnect() },
        fit() { this.el.style.setProperty("--s", String(Math.min(1, this.el.clientWidth / 1280))) }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :idle, :boolean, default: false

  @doc "A peon at its easel, in pixels: dabbing while it draws, napping when idle."
  def easel(assigns) do
    ~H"""
    <canvas
      id={@id}
      class="easel"
      phx-hook=".Easel"
      phx-update="ignore"
      data-idle={@idle && "1"}
      width="144"
      height="34"
      aria-hidden="true"
    ></canvas>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Easel">
      export default {
        mounted() { this.stop = easel(this.el, this.el.dataset.idle === "1") },
        destroyed() { this.stop() }
      }

      // Drawing, the canvas on the easel fills in row by row; idle, the
      // peon sits by the empty easel and naps.
      function easel(canvas, idle) {
        const W = 72, H = 17, S = 2, GY = 16;
        const ctx = canvas.getContext("2d");
        if (!ctx) return () => {};
        ctx.imageSmoothingEnabled = false;
        const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        const ground = getComputedStyle(canvas).getPropertyValue("--text-3").trim() || "#938A82";
        const G = "#8FBF5A", GD = "#6E9B3D", EYE = "#1C2412", TUSK = "#F7F4EA", BARK = "#7A4E2D",
          PAPER = "#FFFFFF", INK = ["#2F5BD3", "#14171C", "#C9CED6", "#2F5BD3", "#E8EEFC"];
        const px = (x, y, w, h, c) => { ctx.fillStyle = c; ctx.fillRect(Math.round(x), Math.round(y), w, h) };
        let frame = 0, raf = 0;
        const draw = () => {
          ctx.setTransform(S, 0, 0, S, 0, 0);
          ctx.clearRect(0, 0, W, H);
          px(8, GY, 56, 1, ground);
          const ex = 40;
          px(ex + 1, 3, 1, 13, BARK); px(ex + 12, 3, 1, 13, BARK); px(ex + 6, 12, 1, 4, BARK);
          px(ex, 2, 14, 10, PAPER);
          const filled = idle ? 0 : Math.floor((frame % 300) / 300 * 36);
          for (let i = 0; i < filled; i++) {
            const r = Math.floor(i / 6), c = i % 6;
            px(ex + 1 + c * 2, 3 + r * 1.4, 2, 1, INK[(r + (r === 0 ? 1 : 0)) % INK.length]);
          }
          if (!idle) px(ex + 1, 3, 12, 1, "#14171C");
          const sx = 28, sy = GY - 9 + (idle ? 1 : 0);
          px(sx + 1, sy, 6, 1, G); px(sx, sy + 1, 8, 6, G); px(sx + 1, sy + 7, 6, 1, G); px(sx, sy + 6, 8, 1, GD);
          if (idle) { px(sx + 2, sy + 3, 2, 1, EYE); px(sx + 5, sy + 3, 2, 1, EYE) }
          else { px(sx + 2, sy + 2, 1, 1, EYE); px(sx + 6, sy + 2, 1, 1, EYE) }
          px(sx + 2, sy + 5, 1, 2, TUSK); px(sx + 6, sy + 5, 1, 2, TUSK);
          if (!idle) {
            px(sx + 2, sy + 8, 1, 1, EYE); px(sx + 5, sy + 8, 1, 1, EYE);
            const reach = frame % 30 < 15;
            px(sx + 8, sy + (reach ? 2 : 4), reach ? 4 : 3, 1, BARK);
            px(sx + (reach ? 12 : 11), sy + (reach ? 1 : 3), 1, 2, INK[0]);
          } else {
            const t = frame % 150;
            if (t < 70) {
              const zx = sx + 8 + Math.floor(t / 24), zy = sy - 1 - Math.floor(t / 14);
              px(zx, zy, 3, 1, ground); px(zx + 1, zy + 1, 1, 1, ground); px(zx, zy + 2, 3, 1, ground);
            }
          }
        };
        const tick = () => { frame += 1; draw(); raf = requestAnimationFrame(tick) };
        if (reduce) draw(); else raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
      }
    </script>
    """
  end

  attr :card, :map, required: true, doc: "`%{state: :drawing | :ready | :landed, change}`"
  attr :live_only?, :boolean, required: true

  @doc "The chat's change when it is boards alone: Submit design lands it, it never ships."
  def design_card(assigns) do
    ~H"""
    <section class="framed ws-cs" aria-label="Boards">
      <div class="csrow">
        <span class="text-[var(--rust)] flex"><.icon name="hero-swatch" class="size-[17px]" /></span>
        <h2 class="m-0 text-[15px] leading-[22px] font-semibold">
          {if @card.change, do: "Change ##{@card.change}", else: "Change"}
        </h2>
        <span class="ptag">design only</span>
        <span class={["st", card_tone(@card.state)]}><span class="dot"></span>{card_word(@card.state)}</span>
        <div class="acts">
          <button
            :if={@card.state == :ready}
            id="submit-design"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="submit_design"
          >
            Submit design
          </button>
        </div>
      </div>
      <div class="muted text-[13px]">{card_note(@card.state, @live_only?)}</div>
    </section>
    """
  end

  defp card_tone(:drawing), do: "warn"
  defp card_tone(_state), do: "ok"

  defp card_word(:drawing), do: "drawing"
  defp card_word(:ready), do: "ready"
  defp card_word(:landed), do: "on main"

  defp card_note(:landed, _live_only?),
    do: "On main, so teammates see the boards. Nothing ships."

  defp card_note(_state, live_only?),
    do:
      "Lands on main right away, without the checks. Boards never ship to " <>
        if(live_only?, do: "live.", else: "prod.")
end
