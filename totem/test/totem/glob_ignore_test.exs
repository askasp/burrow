defmodule Totem.GlobIgnoreTest do
  use ExUnit.Case, async: true

  alias Totem.{Glob, Ignore}

  test "* stays within a segment, ** spans segments" do
    assert Glob.matches?("lib/app/application.ex", ["lib/*/application.ex"])
    refute Glob.matches?("lib/app/sub/application.ex", ["lib/*/application.ex"])
    assert Glob.matches?("deps/a/b.ex", ["deps/**"])
    assert Glob.matches?("x/y.db", ["**.db"])
    refute Glob.matches?("lib/a.ex", ["deps/**", "**.db"])
    refute Glob.matches?("lib/rel/a", ["rel/**"])
  end

  @tag :tmp_dir
  test "the matcher reads the ignore file and takes extra globs", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".totemignore"), "# comment\nsecret/\n\n")
    ignore? = Ignore.matcher(dir, extra: [".agent/**"])

    assert ignore?.("_build/dev/x.beam")
    assert ignore?.("secret/key.pem")
    assert ignore?.(".agent/state")
    refute ignore?.("lib/app.ex")

    assert Ignore.matcher(dir, file: ".other").("lib/app.ex") == false
    refute Ignore.matcher(dir, file: ".other").("secret/key.pem")
  end
end
