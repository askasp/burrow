defmodule Totem do
  @moduledoc """
  Lives inside an Elixir app: owns its files and changes them in place
  (`Totem.Server`), watches it (`Totem.Monitor`), and talks to whoever runs
  it (`Totem.Link`, `Totem.Plug`, `Totem.MCP`).

      Totem.current()
      #=> %{tree: %{"lib/app/x.ex" => "ab12…", …}, hash: "9f3c…", label: "main #12"}

      Totem.apply([{"lib/app/x.ex", "ab12…", new_source}, {"lib/old.ex", "cd34…", :deleted}],
        label: "main #13", watch: 15_000)
      #=> {:ok, %{mode: "hot", output: "Compiling 1 file (.ex)\\n", label: "main #13", …}}

  Each file names the hash it must have now (nil: it must not exist); if one
  doesn't, nothing is written: `{:error, {:conflict, paths}}`. Its paths decide
  how a change loads:

    * hot - most files: recompiled in place, processes keep their state
    * warm - `config/**`, `lib/*/application.ex`, `lib/*_web/endpoint.ex`:
      the app is stopped and started again inside the running node
    * cold - `mix.exs`, `mix.lock`: written, `restart_required: true`;
      restarting the node is up to whoever runs it

  When loading fails the previous files go back and load again:
  `{:error, {:load_failed, mode, output}}`. With `:watch` (ms), an error the
  app logs in that window that wasn't seen before, or the app stopping, does
  the same: `{:error, {:reverted, mode, errors}}`.

  With `config :totem, origin: true` (or `TOTEM_ORIGIN=1`) the node also
  keeps the app's history and takes drafts (`Totem.Origin`).

  Configuration (`config :totem, ...`), all optional: `:root` (the app's
  directory, default the working directory), `:store` (default
  `<root>/.totem`), `:otp_app`, `:cold_paths`, `:warm_paths`, `:asset_paths`,
  `:migration_paths`, `:ignore` (globs that are never code, also
  `TOTEM_IGNORE`, comma-separated), `:watch`, `:origin`, `:repo_dir`,
  `:token`, `server: false` to not start it.
  """

  alias Totem.{Server, Store}

  @source_dir Path.expand("..", __DIR__)

  @doc "Where Totem's own source is, e.g. to mount it where apps are built."
  @spec source_dir() :: Path.t()
  def source_dir, do: @source_dir

  @type file ::
          {String.t(), Totem.Blob.hash() | nil, binary() | {:blob, Totem.Blob.hash()} | :deleted}

  @doc "The files on disk as a tree, its hash, and the label of the last change."
  @spec current() :: %{tree: Totem.Tree.t(), hash: Totem.Blob.hash(), label: String.t() | nil}
  def current, do: call(:current)

  @doc "Writes and loads `files` (see the moduledoc). Options: `:label`, `:watch`."
  @spec apply([file()], keyword()) :: {:ok, map()} | {:error, term()}
  def apply(files, opts \\ []), do: call({:apply, files, opts})

  @doc "A file's content on disk, if it is part of the code."
  @spec read(String.t()) :: {:ok, binary()} | :error
  def read(path) do
    with %{^path => _} <- current().tree,
         {:ok, content} <- File.read(Path.join(info().root, path)) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  @doc "A content sent ahead of a change, by hash."
  @spec blob(Totem.Blob.hash()) :: {:ok, binary()} | :error
  def blob(hash), do: Store.get_blob(info().store, hash)

  @doc "The hashes Totem has no content for; send those, then refer to the rest as `{:blob, hash}`."
  @spec missing([Totem.Blob.hash()]) :: [Totem.Blob.hash()]
  def missing(hashes) do
    %{tree: tree} = current()
    on_disk = MapSet.new(Map.values(tree))
    hashes |> Enum.reject(&MapSet.member?(on_disk, &1)) |> then(&Store.missing(info().store, &1))
  end

  @doc "Stores contents ahead of a change. Returns their hashes."
  @spec put_blobs([binary()]) :: [Totem.Blob.hash()]
  def put_blobs(contents), do: Enum.map(contents, &Store.put_blob(info().store, &1))

  @doc "The files on disk as a .tar.gz, e.g. to check the code out elsewhere."
  @spec archive() :: binary()
  def archive do
    %{root: root, store: store} = info()

    entries =
      for {path, _} <- Enum.sort(current().tree),
          do: {String.to_charlist(path), File.read!(Path.join(root, path))}

    tmp = Path.join([store, "tmp", "archive-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(Path.dirname(tmp))

    try do
      :ok = :erl_tar.create(String.to_charlist(tmp), entries, [:compressed])
      File.read!(tmp)
    after
      File.rm(tmp)
    end
  end

  @doc false
  def info, do: call(:info)

  defp call(request), do: GenServer.call(Server, request, :infinity)
end
