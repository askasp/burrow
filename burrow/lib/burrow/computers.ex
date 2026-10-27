defmodule Burrow.Computers do
  @moduledoc """
  Computers paired through Burrow Bridge (the Go program in `bridge/`), so
  Peon can work on files there, in the folders the computer shares.

  Pairing goes like `gh auth login`: the bridge asks for a code
  (`start_pairing/1`), someone logged in approves it here (`approve/2`),
  and the bridge, polling with its secret device code, takes a token of its
  own (`claim_token/1`). Burrow keeps only hashes of both. `remove/1` takes
  the computer back.

  While its bridge runs, a computer keeps a websocket open
  (`Burrow.Computers.Link`), and `call/4` sends it a tool call and waits
  for the answer. The bridge checks every path against the folders it
  shares, so Burrow can't reach past them; the folders change only there
  (`burrow-bridge allow`, or the folder picker `pick_folder` opens on the
  computer), except that Burrow may stop sharing one.

  Broadcasts `{:computer, id}` (paired, online, offline, renamed, shares
  other folders) and `{:computer_removed, id}` on the user's topic
  (`subscribe/1`).
  """

  import Ecto.Query

  alias Burrow.Repo
  alias Burrow.Computers.Computer

  @registry Burrow.ComputerRegistry
  @pair_ttl 600
  @max_pending 100
  @call_timeout :timer.seconds(60)
  # No 0/O or 1/I, so a code reads back right
  @code_chars ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Burrow.PubSub, "computers:#{user_id}")

  defp broadcast(%Computer{user_id: nil}, _message), do: :ok

  defp broadcast(%Computer{user_id: user_id}, message),
    do: Phoenix.PubSub.broadcast(Burrow.PubSub, "computers:#{user_id}", message)

  ## Pairing

  @doc """
  A computer asks to pair, saying what it is (`name`, `os`, `arch`,
  `version`). Returns the secret it polls with and the code to approve.
  """
  def start_pairing(attrs) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from c in unclaimed(), where: c.pair_expires_at < ^now)

    if Repo.aggregate(unclaimed(), :count) >= @max_pending do
      {:error, :busy}
    else
      device_code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      computer =
        Repo.insert!(%Computer{
          name: clip(attrs["name"], "Computer"),
          os: clip(attrs["os"], "unknown"),
          arch: clip(attrs["arch"], "unknown"),
          version: clip(attrs["version"], nil),
          user_code: user_code(),
          device_code_hash: hash(device_code),
          pair_expires_at: DateTime.add(now, @pair_ttl)
        })

      {:ok, %{device_code: device_code, user_code: computer.user_code, expires_in: @pair_ttl}}
    end
  end

  defp unclaimed, do: from(c in Computer, where: is_nil(c.token_hash))

  defp clip(value, _default) when is_binary(value) and value != "",
    do: value |> String.trim() |> String.slice(0, 80)

  defp clip(_value, default), do: default

  defp user_code do
    code = for _ <- 1..8, into: "", do: <<Enum.random(@code_chars)>>
    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  @doc "The computer waiting for someone to approve `code`, or nil."
  def pending(code) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from c in unclaimed(),
        where: c.user_code == ^normalize(code) and is_nil(c.user_id) and c.pair_expires_at > ^now
    )
  end

  defp normalize(code) do
    case code |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "") do
      <<a::binary-size(4), b::binary-size(4)>> -> a <> "-" <> b
      other -> other
    end
  end

  @doc "`user` approves the computer that shows `code`: it becomes theirs."
  def approve(user, code) do
    case pending(code) do
      nil ->
        {:error, :expired}

      computer ->
        computer
        |> Ecto.Changeset.change(user_id: user.id, approved_at: DateTime.utc_now(:second))
        |> Repo.update()
    end
  end

  @doc "Nobody here asked for `code`: it goes."
  def refuse(code) do
    if computer = pending(code), do: Repo.delete(computer)
    :ok
  end

  @doc """
  The bridge polls with its device code: `{:ok, token, computer}` once the
  code is approved (only once), `:pending` before, else `{:error, :expired}`.
  """
  def claim_token(device_code) when is_binary(device_code) do
    now = DateTime.utc_now(:second)

    case Repo.one(from c in unclaimed(), where: c.device_code_hash == ^hash(device_code)) do
      nil ->
        {:error, :expired}

      computer ->
        cond do
          DateTime.compare(computer.pair_expires_at, now) == :lt ->
            Repo.delete(computer)
            {:error, :expired}

          computer.user_id == nil ->
            :pending

          true ->
            claimed(computer)
        end
    end
  end

  def claim_token(_device_code), do: {:error, :expired}

  defp claimed(computer) do
    token = "bb_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

    computer =
      computer
      |> Ecto.Changeset.change(
        token_hash: hash(token),
        device_code_hash: nil,
        user_code: nil,
        pair_expires_at: nil
      )
      |> Repo.update!()

    broadcast(computer, {:computer, computer.id})
    {:ok, token, computer}
  end

  @doc "The paired computer with this token, or nil."
  def by_token(token) when is_binary(token),
    do:
      Repo.one(from c in Computer, where: c.token_hash == ^hash(token) and not is_nil(c.user_id))

  def by_token(_token), do: nil

  defp hash(secret), do: :crypto.hash(:sha256, secret)

  ## A user's computers

  @doc "The user's paired computers, by name."
  def list(user_id),
    do:
      Repo.all(
        from c in Computer,
          where: c.user_id == ^user_id and not is_nil(c.token_hash),
          order_by: [asc: c.name, asc: c.id]
      )

  @doc "The user's computer `id`, nil when it isn't theirs."
  def get(user_id, id), do: Repo.get_by(Computer, id: id, user_id: user_id)

  def rename(%Computer{} = computer, name) do
    case String.trim(name) do
      "" ->
        {:error, :blank}

      name ->
        computer =
          computer |> Ecto.Changeset.change(name: String.slice(name, 0, 80)) |> Repo.update!()

        broadcast(computer, {:computer, computer.id})
        {:ok, computer}
    end
  end

  @doc "Unpairs the computer: its token stops working and its link closes."
  def remove(%Computer{} = computer) do
    Repo.delete!(computer)
    if pid = link(computer.id), do: send(pid, :removed)
    broadcast(computer, {:computer_removed, computer.id})
    :ok
  end

  ## The link

  @doc "Whether the computer's bridge is connected right now."
  def online?(id), do: link(id) != nil

  defp link(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Runs `method` with `params` on the computer: `{:ok, result}`,
  `{:error, message}` when the bridge refuses or fails, `{:error, :offline}`
  or `{:error, :timeout}`.
  """
  def call(id, method, params \\ %{}, timeout \\ @call_timeout) do
    case link(id) do
      nil ->
        {:error, :offline}

      pid ->
        ref = Process.monitor(pid)
        send(pid, {:call, self(), ref, method, params})

        receive do
          {^ref, reply} ->
            Process.demonitor(ref, [:flush])
            reply

          {:DOWN, ^ref, _, _, _} ->
            {:error, :offline}
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end
    end
  end

  @doc """
  Asks the person at the computer to pick a folder to share, `write` to let
  Peon change files there too. Waits up to five minutes for them.
  """
  def pick_folder(id, write?),
    do: call(id, "pick_folder", %{write: write?}, :timer.minutes(5))

  @doc "Stops sharing a folder (Burrow may narrow what it reaches, never widen it)."
  def forget_folder(id, path), do: call(id, "forget_folder", %{path: path})

  @doc false
  # The bridge connected and said what it is and shares (`Link`).
  def connected(%Computer{} = computer, hello) do
    computer
    |> Ecto.Changeset.change(
      os: clip(hello["os"], computer.os),
      arch: clip(hello["arch"], computer.arch),
      version: clip(hello["version"], computer.version),
      folders: folders(hello["folders"]),
      can_pick: hello["pick"] == true,
      last_seen_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
    |> tap(&broadcast(&1, {:computer, &1.id}))
  end

  @doc false
  def folders_changed(id, folders) do
    with %Computer{} = computer <- Repo.get(Computer, id) do
      computer
      |> Ecto.Changeset.change(folders: folders(folders))
      |> Repo.update!()
      |> tap(&broadcast(&1, {:computer, &1.id}))
    end
  end

  @doc false
  def disconnected(id) do
    with %Computer{} = computer <- Repo.get(Computer, id) do
      computer
      |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second))
      |> Repo.update!()
      |> tap(&broadcast(&1, {:computer, &1.id}))
    end
  end

  defp folders(folders) when is_list(folders) do
    for %{"path" => path} = folder <- folders,
        is_binary(path),
        do: %{"path" => path, "write" => folder["write"] == true}
  end

  defp folders(_folders), do: []

  ## Downloads

  @doc """
  What Burrow Bridge is built for: `{target, os, label}`, target as Go
  names it (`Burrow.Bridge`).
  """
  def targets,
    do: [
      {"darwin-arm64", "Mac", "Apple silicon"},
      {"darwin-amd64", "Mac", "Intel"},
      {"linux-amd64", "Linux", "x86-64"},
      {"linux-arm64", "Linux", "ARM"},
      {"windows-amd64", "Windows", "x86-64"},
      {"windows-arm64", "Windows", "ARM"}
    ]

  @doc "The OS's name as people say it."
  def os_name("darwin"), do: "Mac"
  def os_name("linux"), do: "Linux"
  def os_name("windows"), do: "Windows"
  def os_name(os), do: os
end
