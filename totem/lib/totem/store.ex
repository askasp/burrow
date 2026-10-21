defmodule Totem.Store do
  @moduledoc """
  Contents by hash, as plain files the way git keeps objects:
  `<dir>/objects/ab/cdef…`, zlib-compressed (`Totem.Blob`). Every file is
  written aside and renamed into place, so a crash never leaves half a file.
  """

  alias Totem.Blob

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

  @doc "The hashes in `hashes` this store has no content for."
  @spec missing(Path.t(), [Blob.hash()]) :: [Blob.hash()]
  def missing(dir, hashes), do: Enum.reject(hashes, &File.exists?(object_path(dir, &1)))

  @doc false
  def write!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp#{System.unique_integer([:positive])}"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  defp object_path(dir, <<prefix::binary-size(2), rest::binary>>),
    do: Path.join([dir, "objects", prefix, rest])
end
