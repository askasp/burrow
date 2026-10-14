defmodule PeonCore.Blob do
  @moduledoc "Content-addressed file contents: sha256 hex hash, zlib-compressed storage."

  @type hash :: String.t()

  @spec hash(binary()) :: hash()
  def hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @spec compress(binary()) :: binary()
  def compress(content), do: :zlib.compress(content)

  @spec decompress(binary()) :: binary()
  def decompress(data), do: :zlib.uncompress(data)

  @doc "Returns `{:ok, content}` if `content` hashes to `expected`."
  @spec verify(binary(), hash()) :: {:ok, binary()} | {:error, :hash_mismatch}
  def verify(content, expected) do
    if hash(content) == expected, do: {:ok, content}, else: {:error, :hash_mismatch}
  end
end
