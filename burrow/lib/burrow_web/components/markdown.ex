defmodule BurrowWeb.Markdown do
  @moduledoc """
  A small Markdown reader for Peon's answers, in Chats (`BurrowWeb.ChatsLive`)
  and in a project's chats (`BurrowWeb.WorkspaceLive`):
  paragraphs, headings, lists (one level deep), code blocks, quotes, rules
  and simple tables; inline code, bold, italics, links and citations
  ("[1]"). The page is built from HEEx, so nothing in the text becomes
  markup of its own.
  """

  use Phoenix.Component

  ## Reading

  @doc """
  The text's blocks: `{:p, inlines}`, `{:h, level, inlines}`,
  `{:ol, start, items}`, `{:ul, items}` (an item is `{inlines, sub_items}`),
  `{:code, lang, text}`, `{:quote, inlines}`, `:hr` and
  `{:table, header, rows}` (cells are inlines).
  """
  def parse(text) when is_binary(text), do: text |> String.split(~r/\r?\n/) |> blocks([])

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest] = lines, acc) do
    cond do
      String.trim(line) == "" ->
        blocks(rest, acc)

      match = Regex.run(~r/^\s*(```|~~~)\s*([\w+-]*)/, line) ->
        [_, fence, lang] = match

        {code, rest} =
          Enum.split_while(rest, &(not String.starts_with?(String.trim_leading(&1), fence)))

        blocks(Enum.drop(rest, 1), [{:code, lang, Enum.join(code, "\n")} | acc])

      match = Regex.run(~r/^\s{0,3}(\#{1,6})\s+(.*?)\s*#*\s*$/, line) ->
        [_, hashes, title] = match
        blocks(rest, [{:h, String.length(hashes), inlines(title)} | acc])

      line =~ ~r/^\s{0,3}([-*_])(\s*\1){2,}\s*$/ ->
        blocks(rest, [:hr | acc])

      table?(lines) ->
        {rows, rest} = Enum.split_while(lines, &String.starts_with?(String.trim_leading(&1), "|"))
        [header, _rule | body] = Enum.map(rows, &cells/1)
        blocks(rest, [{:table, header, body} | acc])

      line =~ ~r/^\s{0,3}>/ ->
        {quoted, rest} = Enum.split_while(lines, &(&1 =~ ~r/^\s{0,3}>/))
        text = Enum.map_join(quoted, " ", &String.replace(&1, ~r/^\s{0,3}>\s?/, ""))
        blocks(rest, [{:quote, inlines(text)} | acc])

      match = Regex.run(~r/^(\s*)(\d+)[.)]\s+/, line) ->
        [_, _indent, start] = match
        {items, rest} = list(lines, ~r/^(\s*)\d+[.)]\s+(.*)$/)
        blocks(rest, [{:ol, String.to_integer(start), items} | acc])

      line =~ ~r/^\s*[-*+]\s+/ ->
        {items, rest} = list(lines, ~r/^(\s*)[-*+]\s+(.*)$/)
        blocks(rest, [{:ul, items} | acc])

      true ->
        {more, rest} = Enum.split_while(rest, &paragraph_line?/1)
        blocks(rest, [{:p, inlines(Enum.map_join([line | more], " ", &String.trim/1))} | acc])
    end
  end

  defp paragraph_line?(line) do
    String.trim(line) != "" and
      not (line =~ ~r/^\s*(```|~~~|\#{1,6}\s|>|[-*+]\s|\d+[.)]\s|\|)/) and
      not (line =~ ~r/^\s{0,3}([-*_])(\s*\1){2,}\s*$/)
  end

  defp table?([a, b | _]),
    do: String.starts_with?(String.trim_leading(a), "|") and b =~ ~r/^\s*\|?\s*:?-{2,}/

  defp table?(_lines), do: false

  defp cells(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&inlines(String.trim(&1)))
  end

  # A list's items: lines with its marker start one, deeper ones of any
  # marker go under it, other lines carry on the item they follow.
  defp list(lines, marker), do: list(lines, marker, nil, [])

  defp list([], _marker, _indent, items), do: {finish(items), []}

  defp list([line | rest] = lines, marker, indent, items) do
    sub = Regex.run(~r/^(\s*)(?:[-*+]|\d+[.)])\s+(.*)$/, line)

    cond do
      String.trim(line) == "" ->
        case rest do
          [next | _] when next != "" ->
            if next =~ marker or (sub_of?(next, indent) and items != []),
              do: list(rest, marker, indent, items),
              else: {finish(items), rest}

          _ ->
            {finish(items), rest}
        end

      (m = Regex.run(marker, line)) && (indent == nil or String.length(Enum.at(m, 1)) <= indent) ->
        [_, ws, text] = m
        list(rest, marker, indent || String.length(ws), [{text, []} | items])

      sub && items != [] ->
        [_, _ws, text] = sub
        [{text0, subs} | more] = items
        list(rest, marker, indent, [{text0, [text | subs]} | more])

      items != [] and paragraph_line?(line) ->
        [{text0, subs} | more] = items

        case subs do
          [] ->
            list(rest, marker, indent, [{text0 <> " " <> String.trim(line), []} | more])

          [s | ss] ->
            list(rest, marker, indent, [{text0, [s <> " " <> String.trim(line) | ss]} | more])
        end

      true ->
        {finish(items), lines}
    end
  end

  defp sub_of?(line, indent), do: indent != nil and line =~ ~r/^\s{#{indent + 1},}\S/

  defp finish(items),
    do:
      items
      |> Enum.reverse()
      |> Enum.map(fn {t, subs} ->
        {inlines(t), subs |> Enum.reverse() |> Enum.map(&inlines/1)}
      end)

  @inline ~r/(`[^`\n]+`)|(\*\*[^*\n]+?\*\*)|(__[^_\n]+?__)|(\[\d{1,2}\])|(\[[^\]\n]+\]\(https?:\/\/[^\s)]+\))|(\*[^*\s][^*\n]*?\*)|(https?:\/\/[^\s<>)\]]+[^\s<>)\].,;:!?'"])/

  @doc "A line's inlines: `{:text | :code | :b | :i, text}`, `{:link, text, url}`, `{:cite, n}`."
  def inlines(text) do
    @inline
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&inline/1)
  end

  defp inline("`" <> _ = s) when byte_size(s) > 2, do: {:code, String.slice(s, 1..-2//1)}
  defp inline("**" <> _ = s) when byte_size(s) > 4, do: {:b, String.slice(s, 2..-3//1)}
  defp inline("__" <> _ = s) when byte_size(s) > 4, do: {:b, String.slice(s, 2..-3//1)}

  defp inline("[" <> _ = s) do
    cond do
      m = Regex.run(~r/^\[(\d{1,2})\]$/, s) -> {:cite, String.to_integer(Enum.at(m, 1))}
      m = Regex.run(~r/^\[([^\]]+)\]\((\S+)\)$/, s) -> {:link, Enum.at(m, 1), Enum.at(m, 2)}
      true -> {:text, s}
    end
  end

  defp inline("*" <> _ = s) when byte_size(s) > 2, do: {:i, String.slice(s, 1..-2//1)}
  defp inline("http" <> _ = s), do: {:link, s, s}
  defp inline(s), do: {:text, s}

  ## Showing

  attr :text, :string, required: true
  attr :cites, :any, default: MapSet.new(), doc: "the numbers that are sources"
  attr :turn, :string, default: nil, doc: "the answer's turn, for its citations"
  attr :cited, :any, default: nil, doc: "the citation picked: `{turn, n}`"
  attr :class, :any, default: nil

  @doc "Peon's answer, read as Markdown; its citations are buttons (`cite` events)."
  def markdown(assigns) do
    assigns = assign(assigns, blocks: parse(assigns.text))

    ~H"""
    <div class={["md", @class]}>
      <.block :for={b <- @blocks} block={b} cites={@cites} turn={@turn} cited={@cited} />
    </div>
    """
  end

  attr :block, :any, required: true
  attr :cites, :any, required: true
  attr :turn, :string, required: true
  attr :cited, :any, required: true

  defp block(%{block: {:p, inl}} = assigns) do
    assigns = assign(assigns, inl: inl)
    ~H"<p><.inl items={@inl} cites={@cites} turn={@turn} cited={@cited} /></p>"
  end

  defp block(%{block: {:h, level, inl}} = assigns) do
    assigns = assign(assigns, inl: inl, level: level)

    ~H"""
    <p class={["mdh", @level <= 2 && "big"]}>
      <.inl items={@inl} cites={@cites} turn={@turn} cited={@cited} />
    </p>
    """
  end

  defp block(%{block: {:ol, start, items}} = assigns) do
    assigns = assign(assigns, start: start, items: items)

    ~H"""
    <ol start={if @start != 1, do: @start}>
      <.item :for={i <- @items} item={i} cites={@cites} turn={@turn} cited={@cited} />
    </ol>
    """
  end

  defp block(%{block: {:ul, items}} = assigns) do
    assigns = assign(assigns, items: items)

    ~H"""
    <ul>
      <.item :for={i <- @items} item={i} cites={@cites} turn={@turn} cited={@cited} />
    </ul>
    """
  end

  defp block(%{block: {:code, lang, text}} = assigns) do
    assigns = assign(assigns, lang: lang, text: text)
    ~H|<pre class="mdcode" data-lang={@lang}><code>{@text}</code></pre>|
  end

  defp block(%{block: {:quote, inl}} = assigns) do
    assigns = assign(assigns, inl: inl)
    ~H"<blockquote><.inl items={@inl} cites={@cites} turn={@turn} cited={@cited} /></blockquote>"
  end

  defp block(%{block: :hr} = assigns), do: ~H"<hr />"

  defp block(%{block: {:table, header, rows}} = assigns) do
    assigns = assign(assigns, header: header, rows: rows)

    ~H"""
    <div class="mdtable">
      <table>
        <thead>
          <tr>
            <th :for={c <- @header}><.inl items={c} cites={@cites} turn={@turn} cited={@cited} /></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @rows}>
            <td :for={c <- r}><.inl items={c} cites={@cites} turn={@turn} cited={@cited} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :item, :any, required: true
  attr :cites, :any, required: true
  attr :turn, :string, required: true
  attr :cited, :any, required: true

  defp item(assigns) do
    {inl, subs} = assigns.item
    assigns = assign(assigns, inl: inl, subs: subs)

    ~H"""
    <li>
      <.inl items={@inl} cites={@cites} turn={@turn} cited={@cited} />
      <ul :if={@subs != []}>
        <li :for={s <- @subs}><.inl items={s} cites={@cites} turn={@turn} cited={@cited} /></li>
      </ul>
    </li>
    """
  end

  attr :items, :list, required: true
  attr :cites, :any, required: true
  attr :turn, :string, required: true
  attr :cited, :any, required: true

  # No whitespace between the pieces: a citation sits right after its sentence.
  defp inl(assigns) do
    ~H"""
    <span class="mdi" phx-no-format><%= for i <- @items do %><.piece piece={i} cites={@cites} turn={@turn} cited={@cited} /><% end %></span>
    """
  end

  attr :piece, :any, required: true
  attr :cites, :any, required: true
  attr :turn, :string, required: true
  attr :cited, :any, required: true

  defp piece(%{piece: {:text, text}} = assigns) do
    assigns = assign(assigns, t: text)
    ~H"{@t}"
  end

  defp piece(%{piece: {:code, text}} = assigns) do
    assigns = assign(assigns, t: text)
    ~H"<code>{@t}</code>"
  end

  defp piece(%{piece: {:b, text}} = assigns) do
    assigns = assign(assigns, t: text)
    ~H"<strong>{@t}</strong>"
  end

  defp piece(%{piece: {:i, text}} = assigns) do
    assigns = assign(assigns, t: text)
    ~H"<em>{@t}</em>"
  end

  defp piece(%{piece: {:link, text, url}} = assigns) do
    assigns = assign(assigns, t: text, url: url)
    ~H|<a href={@url} target="_blank" rel="noopener noreferrer">{@t}</a>|
  end

  defp piece(%{piece: {:cite, n}} = assigns) do
    assigns = assign(assigns, n: n, on: assigns.cited == {assigns.turn, n})

    if MapSet.member?(assigns.cites, n) do
      ~H"""
      <button
        type="button"
        class="cite"
        aria-label={"Source #{@n}"}
        aria-pressed={to_string(@on)}
        phx-click="cite"
        phx-value-turn={@turn}
        phx-value-n={@n}
      >{@n}</button>
      """
    else
      ~H"[{@n}]"
    end
  end
end
