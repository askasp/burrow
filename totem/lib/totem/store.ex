defmodule Totem.Store do
  @moduledoc """
  An app's code as Totem keeps it: plain files under one directory, the way
  git keeps objects, so it needs no database and survives a crash mid-write
  (every file is written aside and renamed into place).

      objects/ab/cdef…       one zlib-compressed file per distinct content (`Totem.Blob`)
      versions/000012.json   {"version", "parent", "tree", "mode", "source", "status", "at"}
      current                the version the node runs, e.g. "12"

  A version's tree is `path => blob hash` (`Totem.Tree`), so a version costs
  one small JSON file plus the blobs no earlier version had.
  """

  alias Totem.Blob

  @type version :: %{
          version: pos_integer(),
          parent: pos_integer() | nil,
          tree: Totem.Tree.t(),
          mode: String.t(),
          source: String.t() | nil,
          status: String.t(),
          at: String.t()
        }

  @doc "Stores `content` (once) and returns its hash."
  @spec put_blob(Path.t(), binary()) :: Blob.hash()
  def put_blob(dir, content) do
    hash = Blob.hash(content)
    path = object_path(dir, hash)
    unless File.exists?(path), do: write!(path, Blob.compress(content))
    hash
  end

  @spec get_blob(Path.t(), Blob.hash()) :: {:ok, binary()} | :error
  def get_blob(dir, hash) do
    with {:ok, data} <- File.read(object_path(dir, hash)),
         {:ok, content} <- Blob.verify(Blob.decompress(data), hash) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  @doc "The hashes in `hashes` this store has no blob for."
  @spec missing(Path.t(), [Blob.hash()]) :: [Blob.hash()]
  def missing(dir, hashes), do: Enum.reject(hashes, &File.exists?(object_path(dir, &1)))

  @doc "Records the next version and makes it current. Every blob in `tree` must be stored."
  @spec put_version(Path.t(), map()) :: version()
  def put_version(dir, attrs) do
    parent = current(dir)

    version = %{
      version: (last(dir) || 0) + 1,
      parent: parent,
      tree: Map.fetch!(attrs, :tree),
      mode: Map.get(attrs, :mode, "found"),
      source: Map.get(attrs, :source),
      status: Map.get(attrs, :status, "loaded"),
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    write!(version_path(dir, version.version), JSON.encode!(version))
    set_current(dir, version.version)
    version
  end

  @doc "Rewrites a version's status, e.g. once a version that waited for a restart runs."
  @spec put_status(Path.t(), version(), String.t()) :: version()
  def put_status(dir, version, status) do
    version = %{version | status: status}
    write!(version_path(dir, version.version), JSON.encode!(version))
    version
  end

  @spec version(Path.t(), pos_integer()) :: version() | nil
  def version(dir, n) do
    case File.read(version_path(dir, n)) do
      {:ok, json} -> decode(json)
      {:error, _} -> nil
    end
  end

  @doc "The current version's number, nil before the first one."
  @spec current(Path.t()) :: pos_integer() | nil
  def current(dir) do
    case File.read(Path.join(dir, "current")) do
      {:ok, n} -> String.to_integer(String.trim(n))
      {:error, _} -> nil
    end
  end

  @spec set_current(Path.t(), pos_integer()) :: :ok
  def set_current(dir, n), do: write!(Path.join(dir, "current"), Integer.to_string(n))

  @doc "Every version, newest first."
  @spec versions(Path.t()) :: [version()]
  def versions(dir) do
    dir
    |> Path.join("versions/*.json")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.map(&(&1 |> File.read!() |> decode()))
  end

  defp last(dir) do
    case dir |> Path.join("versions/*.json") |> Path.wildcard() |> Enum.max(fn -> nil end) do
      nil -> nil
      path -> path |> Path.basename(".json") |> String.to_integer()
    end
  end

  defp decode(json) do
    map = JSON.decode!(json)

    %{
      version: map["version"],
      parent: map["parent"],
      tree: map["tree"],
      mode: map["mode"],
      source: map["source"],
      status: map["status"],
      at: map["at"]
    }
  end

  defp object_path(dir, <<prefix::binary-size(2), rest::binary>>),
    do: Path.join([dir, "objects", prefix, rest])

  defp version_path(dir, n),
    do: Path.join([dir, "versions", String.pad_leading(Integer.to_string(n), 6, "0") <> ".json"])

  defp write!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end
end
