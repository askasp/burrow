defmodule Burrow.GeneralChats.Sources do
  @moduledoc """
  What a general chat's answer cites. Peon marks a sentence with [1], [2]
  and ends an answer that cites anything with a block
  (`Burrow.GeneralChat`'s instructions):

      Sources:
      [1] Page title | https://example.com/page | "a short quote"

  `split/1` takes the block off the answer; `pages/1` reads the pages the
  agent searched and fetched so far, for while it searches.
  """

  @doc """
  `{answer, sources}`: the answer without its sources block, and the block
  as `[%{n, title, url, site, quote}]` (none without one).
  """
  def split(text) when is_binary(text) do
    with [_, answer, block] <-
           Regex.run(
             ~r/\A(.*)\n[ \t]*(?:\*\*|#+[ \t]*)?Sources:?(?:\*\*)?:?[ \t]*\n(.*)\z/si,
             text
           ),
         [_ | _] = sources <- block |> String.split("\n") |> Enum.flat_map(&source/1) do
      {String.trim_trailing(answer), sources}
    else
      _ -> {text, []}
    end
  end

  defp source(line) do
    case Regex.run(~r/^\s*[-*]?\s*\[(\d+)\]\s*(.+?)\s*$/, line) do
      [_, n, rest] ->
        case Regex.run(~r{https?://[^\s|"'<>)\]]+}, rest) do
          [url] ->
            {title, quote} = title_and_quote(rest, url)
            [%{n: String.to_integer(n), title: title, url: url, site: site(url), quote: quote}]

          nil ->
            []
        end

      nil ->
        []
    end
  end

  defp title_and_quote(rest, url) do
    [before | after_url] = String.split(rest, url, parts: 2)
    title = before |> String.trim() |> String.trim_trailing("|") |> trim_dash() |> String.trim()

    quote =
      after_url
      |> Enum.join()
      |> String.trim()
      |> String.trim_leading("|")
      |> trim_dash()
      |> String.trim()
      |> String.trim(~s("))
      |> String.trim("“")
      |> String.trim("”")

    {if(title == "", do: site(url), else: title), if(quote == "", do: nil, else: quote)}
  end

  defp trim_dash(text),
    do: text |> String.trim() |> String.trim_leading("—") |> String.trim_trailing("—")

  @doc "A page's site: its host, without www."
  def site(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> url
    end
  end

  @doc """
  The pages the agent's web tools found, in order, from their calls:
  `[%{tool, input, output}]`, tool "websearch" or "webfetch". Returns
  `[%{url, title, site, read?}]`, each page once; `read?` when the agent
  fetched it.
  """
  def pages(calls) do
    calls
    |> Enum.flat_map(fn
      %{tool: "webfetch", input: %{"url" => url}} when is_binary(url) ->
        [%{url: url, title: nil, read?: true}]

      %{tool: "websearch", output: output} when is_binary(output) ->
        output |> found() |> Enum.map(&Map.put(&1, :read?, false))

      _ ->
        []
    end)
    |> Enum.reduce([], fn page, seen ->
      case Enum.find_index(seen, &(&1.url == page.url)) do
        nil ->
          [page | seen]

        i ->
          List.update_at(
            seen,
            i,
            &%{&1 | title: &1.title || page.title, read?: &1.read? or page.read?}
          )
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Map.put(&1, :site, site(&1.url)))
  end

  @doc """
  What a turn cites when its answer has no sources block: the pages the
  agent read, else the first few it found, numbered in order.
  """
  def fallback(pages) do
    read = Enum.filter(pages, & &1.read?)
    picked = if read != [], do: read, else: Enum.take(pages, 5)

    for {page, i} <- Enum.with_index(picked, 1),
        do: %{n: i, title: page.title || page.site, url: page.url, site: page.site, quote: nil}
  end

  # Search results as opencode's web search tool gives them: a
  # "## [Title](url)" heading per result; else "Title:"/"URL:" lines, else the
  # links in it.
  defp found(output) do
    cond do
      (results = Regex.scan(~r/^##[ \t]+\[(.+?)\]\((https?:\/\/[^\s)]+)\)/m, output)) != [] ->
        for [_, title, url] <- results, do: %{url: url, title: String.trim(title)}

      (results = Regex.scan(~r/^Title:[ \t]*(.+)\n(?:.*\n)*?URL:[ \t]*(\S+)/mi, output)) != [] ->
        for [_, title, url] <- results, do: %{url: url, title: String.trim(title)}

      true ->
        for [url] <- Regex.scan(~r{https?://[^\s"'<>)\]]+}, output), do: %{url: url, title: nil}
    end
  end
end
