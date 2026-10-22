defmodule Burrow.BuildCacheTest do
  use ExUnit.Case, async: false

  alias Burrow.BuildCache

  @root Path.join(Application.compile_env!(:burrow, :data_dir), "cache/build")

  setup do
    File.rm_rf!(@root)
    dir = Path.join(System.tmp_dir!(), "build-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.lock"), ~s(%{"jason": {:hex, :jason, "1.4.5"}}))

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(@root)
    end)

    %{dir: dir}
  end

  defp cache(name, files) do
    for {path, content} <- files do
      path = Path.join([@root, name, path])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end
  end

  test "a fresh checkout gets the cache's deps and builds", %{dir: dir} do
    cache("one", %{"deps/jason/mix.exs" => "jason", "_build/dev/lib/jason/ebin/x" => "beam"})

    BuildCache.seed(dir)

    assert File.read!(Path.join(dir, "deps/jason/mix.exs")) == "jason"
    assert File.read!(Path.join(dir, "_build/dev/lib/jason/ebin/x")) == "beam"
  end

  test "a checkout with deps or builds keeps its own", %{dir: dir} do
    cache("one", %{"deps/jason/mix.exs" => "cached", "_build/dev/lib/jason/ebin/x" => "cached"})
    File.mkdir_p!(Path.join(dir, "_build"))

    BuildCache.seed(dir)

    refute File.exists?(Path.join(dir, "deps"))
  end

  test "without a cache nothing is copied", %{dir: dir} do
    BuildCache.seed(dir)
    refute File.exists?(Path.join(dir, "deps"))
  end
end
