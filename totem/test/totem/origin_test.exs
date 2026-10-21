defmodule Totem.OriginTest do
  # A dev app that is its own origin (TOTEM_ORIGIN=1): two agents' drafts
  # against the same change, checked in scratch builds, both landing and
  # loading hot; one that breaks the build fails its check; a change the app
  # takes badly is undone on main too.
  use ExUnit.Case, async: true

  import Totem.Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @test_files [
    {"test/test_helper.exs", "ExUnit.start()\n"},
    {"test/demo_test.exs",
     """
     defmodule DemoTest do
       use ExUnit.Case
       test "it has a label", do: assert(is_binary(Demo.Counter.label()))
     end
     """}
  ]

  test "drafts check, land in parallel and load; a bad one fails or is undone", %{
    tmp_dir: tmp_dir
  } do
    dir = app!(tmp_dir, files: @test_files)

    result =
      run!(
        dir,
        """
        alias Totem.{Origin, Repo}
        path = "lib/demo/counter.ex"
        source = File.read!(path)
        base = Origin.head()

        a = String.replace(source, ~s(def label, do: "v1"), ~s(def label, do: "a"))
        b = String.replace(source, "def greeting,", "def other, do: :b\\n  def greeting,")
        {:ok, _} = Origin.write_draft("a", base, [{path, a}], "label a")
        {:ok, _} = Origin.write_draft("b", base, [{path, b}], "other b")
        {:ok, _} = Origin.check("a")
        {:ok, landed_a} = Origin.land("a")
        {:ok, landed_b} = Origin.land("b")

        broken = "defmodule Demo.Counter do\\n  def label, do:\\nend\\n"
        {:ok, _} = Origin.write_draft("c", nil, [{path, broken}], "breaks it")
        {:error, output} = Origin.check("c")

        File.write!("NOTES.md", "by hand\\n")
        boom = String.replace(File.read!(path), ~s(def label, do: "a"), ~s(def label, do: raise "boom"))
        {:ok, _} = Origin.write_draft("d", nil, [{path, boom}], "raises")
        Task.start(fn -> Enum.each(1..40, fn _ -> Process.sleep(100); Demo.Counter.label() end) end)
        {:error, {:reverted, "hot", _}} = Origin.land("d", watch: 2_000)

        log = for c <- Repo.log(Origin.dir()), do: c.intent

        %{
          landed: [landed_a.mode, landed_a.change, landed_b.change],
          running: [Demo.Counter.label(), Demo.Counter.other()],
          check: [Repo.draft(Origin.dir(), "a").status, Repo.draft(Origin.dir(), "c").status, output =~ "error"],
          log: log,
          label: Totem.current().label
        }
        """,
        [{"TOTEM_ORIGIN", "1"}]
      )

    assert result["landed"] == ["hot", 2, 3]
    assert result["running"] == ["a", "b"]
    assert result["check"] == ["landed", "failed", true]
    # newest first: the revert of "raises", "raises", what was found on disk, b, a, the import
    assert [revert, "raises", "Found on disk", "other b", "label a", "Import"] = result["log"]
    assert revert =~ "Revert #5"
    assert result["label"] == "main #3"
  end
end
