defmodule Mix.Tasks.Totem.Promote do
  @shortdoc "Makes one app run a change from another app's history"
  @moduledoc """
      mix totem.promote https://dev/_totem https://prod/_totem [change] [--watch 30]

  Makes the second app run the first one's change (default: its main),
  whole: it sends only the contents the second app is missing, applies the
  difference to what it runs now, and watches it for `--watch` seconds
  (default 30); a new error undoes it there. Tokens: `SRC_TOKEN` and
  `DST_TOKEN`, each defaulting to `TOTEM_TOKEN`.
  """
  use Mix.Task

  alias Totem.{Remote, Tree}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [watch: :integer])

    case rest do
      [src, dst | change] ->
        promote(trim(src), trim(dst), List.first(change), opts[:watch] || 30)

      _ ->
        Mix.raise("Usage: mix totem.promote SRC_URL DST_URL [CHANGE]")
    end
  end

  defp promote(src, dst, change, watch) do
    src_token = System.get_env("SRC_TOKEN")
    dst_token = System.get_env("DST_TOKEN")
    query = if change, do: "/tree?at=#{change}", else: "/tree"
    {200, %{"id" => id, "tree" => target}} = Remote.get!(src, query, src_token)
    {200, %{"tree" => now}} = Remote.get!(dst, "/current", dst_token)
    changes = Tree.changes(now, target)
    hashes = for {_path, hash} <- changes, hash != :deleted, uniq: true, do: hash

    {200, %{"missing" => missing}} =
      Remote.post!(dst, "/missing", %{"hashes" => hashes}, dst_token)

    contents =
      for hash <- missing do
        {200, file} = Remote.get!(src, "/blobs/#{hash}", src_token)
        file
      end

    if contents != [],
      do: {200, _} = Remote.post!(dst, "/blobs", %{"contents" => contents}, dst_token)

    files =
      for {path, hash} <- changes do
        if hash == :deleted,
          do: %{"path" => path, "from" => now[path], "deleted" => true},
          else: %{"path" => path, "from" => now[path], "blob" => hash}
      end

    label = "#{src} ##{id}"
    body = %{"files" => files, "label" => label, "watch" => watch * 1000}

    case apply(dst, body, dst_token, label, watch) do
      {200, %{"mode" => mode}} ->
        Mix.shell().info("#{dst} runs ##{id} now (#{length(changes)} files, #{mode})")

      {_status, %{"error" => "reverted", "errors" => errors}} ->
        Mix.raise("Undone there, it logged: #{hd(errors)["message"]}")

      {status, error} ->
        Mix.raise("#{status}: #{inspect(error)}")
    end
  end

  # A warm or cold change restarts the app, and with it the web server that
  # was answering: then wait until it says it runs the change.
  defp apply(dst, body, token, label, watch) do
    Remote.post!(dst, "/apply", body, token)
  rescue
    Mix.Error -> wait(dst, token, label, watch + 120)
  end

  defp wait(dst, token, label, tries) do
    Process.sleep(1_000)

    case current(dst, token) do
      {200, %{"label" => ^label}} -> {200, %{"mode" => "restarted"}}
      _ when tries > 0 -> wait(dst, token, label, tries - 1)
      _ -> Mix.raise("#{dst} did not come back running #{label}")
    end
  end

  defp current(dst, token) do
    Remote.get!(dst, "/current", token)
  rescue
    Mix.Error -> nil
  end

  defp trim(url), do: String.trim_trailing(url, "/")
end
