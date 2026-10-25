defmodule Burrow.Tickets do
  @moduledoc """
  A chat's queue: `tk` tickets, one markdown file each with YAML front
  matter, in the chat's own `tickets/` folder (`Burrow.Chat.tickets_dir/2`),
  outside its checkout so they are never part of its change. The agent's
  container mounts it at /peon/tickets with `TICKETS_DIR` set, and `tk`
  itself (`priv/tk`). The agent splits its work into tickets and takes them
  one by one; while any is unfinished it keeps going
  (`Burrow.Chat.KeepGoing`). The user sees the queue, adds to it and deletes
  tickets that haven't started.
  """

  @statuses ~w(open in_progress closed)

  @doc """
  The tickets in `dir`: `[%{id, title, status, priority, deps, created}]`,
  the one in progress first, then the open ones by priority (0 is highest)
  and age, then the closed ones, latest first.
  """
  def list(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&read(Path.join(dir, &1)))
        |> sort()

      {:error, _} ->
        []
    end
  end

  defp sort(tickets) do
    {closed, rest} = Enum.split_with(tickets, &(&1.status == "closed"))

    Enum.sort_by(rest, &{&1.status != "in_progress", &1.priority, &1.created}) ++
      Enum.sort_by(closed, & &1.created, :desc)
  end

  def unfinished(tickets), do: Enum.reject(tickets, &(&1.status == "closed"))

  @doc "Adds an open ticket titled `title`, as `tk create` would. Returns `{:ok, id}`."
  def create(dir, title, description \\ "") do
    title = title |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 200)
    File.mkdir_p!(dir)
    id = new_id(dir)
    # Finer than tk's seconds: the user adds several in a row, and they keep their order.
    created = DateTime.utc_now() |> DateTime.to_iso8601()
    description = String.trim(description)

    File.write!(path(dir, id), """
    ---
    id: #{id}
    status: open
    deps: []
    links: []
    created: #{created}
    type: task
    priority: 2
    ---
    # #{if title == "", do: "Untitled", else: title}
    #{if description != "", do: "\n" <> description <> "\n"}\
    """)

    {:ok, id}
  end

  @doc "Deletes a ticket the agent hasn't started; started and closed ones stay."
  def delete(dir, id) do
    with true <- valid_id?(id) || {:error, :not_found},
         [ticket] <- read(path(dir, id)) do
      if ticket.status == "open",
        do: File.rm(path(dir, id)),
        else: {:error, :started}
    else
      [] -> {:error, :not_found}
      error -> error
    end
  end

  @doc "What the queue looks like, to tell whether a turn moved it."
  def fingerprint(tickets), do: Enum.map(tickets, &{&1.id, &1.status}) |> Enum.sort()

  defp read(file) do
    with {:ok, text} <- File.read(file),
         [_, front, body] <- Regex.run(~r/\A---\n(.*?)\n---\n?(.*)\z/s, text) do
      fields =
        for line <- String.split(front, "\n"),
            [key, value] <- [String.split(line, ":", parts: 2)],
            into: %{},
            do: {String.trim(key), String.trim(value)}

      status = if fields["status"] in @statuses, do: fields["status"], else: "open"

      [
        %{
          id: fields["id"] || Path.basename(file, ".md"),
          title: title(body),
          status: status,
          priority: priority(fields["priority"]),
          deps: list_field(fields["deps"]),
          created: fields["created"] || ""
        }
      ]
    else
      _ -> []
    end
  end

  defp title(body) do
    case Regex.run(~r/^# (.+)$/m, body) do
      [_, title] -> String.trim(title)
      nil -> "Untitled"
    end
  end

  defp priority(value) do
    case Integer.parse(value || "") do
      {n, _} -> n
      :error -> 2
    end
  end

  defp list_field(value),
    do:
      (value || "")
      |> String.trim("[")
      |> String.trim("]")
      |> String.split(~r/[,\s]+/, trim: true)

  # The ids `tk create` makes in the agent's /app: "app-" and four characters.
  defp new_id(dir) do
    id =
      "app-" <>
        for(_ <- 1..4, into: "", do: <<Enum.random(~c"abcdefghijklmnopqrstuvwxyz0123456789")>>)

    if File.exists?(path(dir, id)), do: new_id(dir), else: id
  end

  defp valid_id?(id), do: is_binary(id) and id =~ ~r/\A[\w.-]+\z/

  defp path(dir, id), do: Path.join(dir, id <> ".md")
end
