defmodule Totem.ApplyTest do
  # Totem in a real app: a Mix project of its own with a stateful GenServer,
  # run with `mix run <script>` so Totem loads code into that app's node, as
  # it does under `mix phx.server`. Each script prints one JSON result.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  import Totem.Fixture

  setup %{tmp_dir: tmp_dir}, do: %{dir: app!(tmp_dir)}

  # In the scripts: the hash a file has on disk now, for `from`.
  @now "now = fn path -> Totem.current().tree[path] end\n"

  test "a hot change keeps the process and its state; a stale `from` or a compile error changes nothing",
       %{dir: dir} do
    result =
      run!(
        dir,
        @now <>
          """
          path = "lib/demo/counter.ex"
          Demo.Counter.bump()
          Demo.Counter.bump()
          pid = Process.whereis(Demo.Counter)
          v1 = now.(path)
          v2 = String.replace(File.read!(path), ~s("v1"), ~s("v2"))
          {:ok, hot} = Totem.apply([{path, v1, v2}], label: "main #2")

          stale = Totem.apply([{path, v1, "x"}, {"NOTES.md", nil, "notes"}])
          broken = "defmodule Demo.Counter do\\n  def label, do:\\nend\\n"
          {:error, {:load_failed, "hot", output}} = Totem.apply([{path, now.(path), broken}])

          %{
            hot: [hot.mode, hot.label],
            label: Demo.Counter.label(),
            count: Demo.Counter.count(),
            same_pid: Process.whereis(Demo.Counter) == pid,
            stale: inspect(stale),
            notes: File.exists?("NOTES.md"),
            output_has_error: output =~ "error",
            after_error: [Demo.Counter.label(), File.read!(path) =~ ~s("v2"), Totem.current().label]
          }
          """
      )

    assert result["hot"] == ["hot", "main #2"]
    assert result["label"] == "v2"
    assert result["count"] == 2
    assert result["same_pid"]
    assert result["stale"] == ~s({:error, {:conflict, ["lib/demo/counter.ex"]}})
    refute result["notes"]
    assert result["output_has_error"]
    assert result["after_error"] == ["v2", true, "main #2"]
  end

  test "a config change restarts the app inside the node; mix.exs waits for a restart", %{
    dir: dir
  } do
    result =
      run!(
        dir,
        @now <>
          """
          Demo.Counter.bump()
          pid = Process.whereis(Demo.Counter)
          config = ~s(import Config\\nconfig :demo, greeting: "hi"\\n)
          {:ok, warm} = Totem.apply([{"config/config.exs", now.("config/config.exs"), config}])
          {:ok, cold} = Totem.apply([{"mix.exs", now.("mix.exs"), File.read!("mix.exs") <> "\\n# x\\n"}])

          %{
            warm: warm.mode,
            greeting: Demo.Counter.greeting(),
            count: Demo.Counter.count(),
            new_pid: Process.whereis(Demo.Counter) != pid,
            cold: [cold.mode, cold.restart_required]
          }
          """
      )

    assert result["warm"] == "warm"
    assert result["greeting"] == "hi"
    assert result["count"] == 0
    assert result["new_pid"]
    assert result["cold"] == ["cold", true]
  end

  test "a new error inside the watch window undoes the change; known errors and deletes don't", %{
    dir: dir
  } do
    result =
      run!(
        dir,
        @now <>
          """
          require Logger
          path = "lib/demo/counter.ex"
          Logger.error("an old problem")
          Process.sleep(200)

          extra = "defmodule Demo.Extra do\\n  def hi, do: :hi\\nend\\n"
          {:ok, _} = Totem.apply([{"lib/demo/extra.ex", nil, extra}])
          Logger.error("an old problem")
          {:ok, deleted} = Totem.apply([{"lib/demo/extra.ex", now.("lib/demo/extra.ex"), :deleted}], watch: 500)

          boom = String.replace(File.read!(path), ~s(def label, do: "v1"), ~s(def label, do: raise "boom"))
          # Something keeps calling the code; the new one raises once it loads.
          Task.start(fn -> Enum.each(1..40, fn _ -> Process.sleep(100); Demo.Counter.label() end) end)
          {:error, {:reverted, "hot", [error | _]}} = Totem.apply([{path, now.(path), boom}], watch: 2_000)

          %{
            deleted: [deleted.mode, Code.ensure_loaded?(Demo.Extra)],
            error: error["message"],
            fingerprint: is_binary(error["fingerprint"]),
            label: Demo.Counter.label()
          }
          """
      )

    assert result["deleted"] == ["hot", false]
    assert result["error"] =~ "boom"
    assert result["fingerprint"]
    assert result["label"] == "v1"
  end

  test "current, read, blobs and the archive", %{dir: dir} do
    result =
      run!(dir, """
      [hash] = Totem.put_blobs(["new\\n"])
      missing = Totem.missing([hash, Totem.current().tree["mix.exs"], Totem.Blob.hash("nope")])
      {:ok, _} = Totem.apply([{"NOTES.md", nil, {:blob, hash}}], label: "notes")
      {:ok, files} = :erl_tar.extract({:binary, Totem.archive()}, [:memory, :compressed])

      %{
        missing: missing == [Totem.Blob.hash("nope")],
        read: elem(Totem.read("NOTES.md"), 1),
        label: Totem.current().label,
        hash: Totem.current().hash == Totem.Tree.hash(Totem.current().tree),
        names: files |> Enum.map(fn {name, _} -> to_string(name) end) |> Enum.sort(),
        bad: inspect(Totem.apply([{"../x.ex", nil, "x"}]))
      }
      """)

    assert result["missing"]
    assert result["read"] == "new\n"
    assert result["label"] == "notes"
    assert result["hash"]

    assert result["names"] ==
             ~w(NOTES.md config/config.exs lib/demo/application.ex lib/demo/counter.ex mix.exs)

    assert result["bad"] =~ "bad_path"
  end
end
