defmodule Totem do
  @moduledoc """
  Lives inside an Elixir app and owns its code: what runs now, every version
  before it (`Totem.Store`), and changing it in place (`Totem.Loader`).

      Totem.current()
      #=> %{version: 12, tree: %{"lib/app/x.ex" => "ab12…", …}, mode: "hot", …}

      Totem.apply(%{base: 12, files: [{"lib/app/x.ex", source}, {"lib/old.ex", :deleted}]})
      #=> {:ok, %{version: 13, mode: "hot", output: "Compiling 1 file (.ex)\\n"}}

  A change names the version it was made against (`:base`), and is refused
  with `{:error, {:conflict, current}}` when that isn't current anymore. Its
  paths decide how it loads:

    * hot - most files: recompiled in place, processes keep their state
    * warm - `config/**`, `lib/*/application.ex`, `lib/*_web/endpoint.ex`:
      the app is stopped and started again inside the running node
    * cold - `mix.exs`, `mix.lock`: written and recorded as
      `"restart_required"`; restarting the node is up to whoever runs it

  When a hot or warm load fails, the previous version's files go back on
  disk and load again, so the old code keeps running, and the compiler's
  output comes back in `{:error, {:load_failed, mode, output}}`.

  Files changed on disk outside Totem become a version of their own
  (`mode: "found"`) the next time Totem looks.

  Configuration (`config :totem, ...`), all optional: `:root` (the app's
  directory, default the working directory), `:store` (default
  `<root>/.totem`), `:otp_app` (default the Mix project's app),
  `:cold_paths`, `:warm_paths`, `server: false` to not start it.
  """

  alias Totem.{Server, Store}

  @type file :: {String.t(), binary() | {:blob, Totem.Blob.hash()} | :deleted}
  @type change :: %{base: pos_integer(), files: [file()]}

  @doc "The version this node runs (recording what's on disk first if it changed)."
  @spec current() :: Store.version()
  def current, do: call(:current)

  @doc "Every version, newest first."
  @spec versions() :: [Store.version()]
  def versions, do: Store.versions(store())

  @doc "A file's content in the current version."
  @spec read(String.t()) :: {:ok, binary()} | :error
  def read(path) do
    case current().tree do
      %{^path => hash} -> Store.get_blob(store(), hash)
      _ -> :error
    end
  end

  @doc "A stored content by its hash."
  @spec blob(Totem.Blob.hash()) :: {:ok, binary()} | :error
  def blob(hash), do: Store.get_blob(store(), hash)

  @doc "The hashes Totem has no content for; send those, then refer to the rest as `{:blob, hash}`."
  @spec missing([Totem.Blob.hash()]) :: [Totem.Blob.hash()]
  def missing(hashes), do: Store.missing(store(), hashes)

  @doc "Stores contents ahead of a change. Returns their hashes."
  @spec put_blobs([binary()]) :: [Totem.Blob.hash()]
  def put_blobs(contents), do: Enum.map(contents, &Store.put_blob(store(), &1))

  @doc """
  Applies a change and loads it. Options: `:source`, a label kept with the
  version (e.g. `"peon#12"`).
  """
  @spec apply(change(), keyword()) ::
          {:ok, %{version: pos_integer(), mode: String.t(), output: String.t()}}
          | {:error, term()}
  def apply(change, opts \\ []), do: call({:apply, change, opts})

  @doc "Makes version `n`'s code current again, as a new version."
  @spec rollback(pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback(n, opts \\ []), do: call({:rollback, n, opts})

  @doc "The current version's files as a .tar.gz, e.g. to check the code out elsewhere."
  @spec archive() :: binary()
  def archive do
    %{tree: tree, version: version} = current()
    dir = store()

    entries =
      for {path, hash} <- Enum.sort(tree) do
        {:ok, content} = Store.get_blob(dir, hash)
        {String.to_charlist(path), content}
      end

    tmp = Path.join([dir, "tmp", "archive-#{version}-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(Path.dirname(tmp))

    try do
      :ok = :erl_tar.create(String.to_charlist(tmp), entries, [:compressed])
      File.read!(tmp)
    after
      File.rm(tmp)
    end
  end

  defp store, do: call(:info).store

  defp call(request), do: GenServer.call(Server, request, :infinity)
end
