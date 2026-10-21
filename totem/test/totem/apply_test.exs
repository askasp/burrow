defmodule Totem.ApplyTest do
  # Totem in a real app: a Mix project of its own with a stateful GenServer,
  # run with `mix run <script>` so Totem loads code into that app's node, as
  # it does under `mix phx.server`. Each script prints one JSON result.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  import Totem.Fixture

  setup %{tmp_dir: tmp_dir}, do: %{dir: app!(tmp_dir)}

  test "a hot change keeps the process and its state; a compile error rolls back", %{dir: dir} do
    result =
      run!(dir, """
      Demo.Counter.bump()
      Demo.Counter.bump()
      pid = Process.whereis(Demo.Counter)
      first = Totem.current()
      v2 = String.replace(File.read!("lib/demo/counter.ex"), ~s("v1"), ~s("v2"))
      {:ok, hot} = Totem.apply(%{base: first.version, files: [{"lib/demo/counter.ex", v2}]}, source: "test")

      stale = Totem.apply(%{base: first.version, files: [{"lib/demo/counter.ex", "x"}]})

      broken = "defmodule Demo.Counter do\\n  def label, do:\\nend\\n"
      {:error, {:load_failed, "hot", output}} =
        Totem.apply(%{base: hot.version, files: [{"lib/demo/counter.ex", broken}]})

      %{
        first: first.mode,
        hot: hot.mode,
        label: Demo.Counter.label(),
        count: Demo.Counter.count(),
        same_pid: Process.whereis(Demo.Counter) == pid,
        stale: inspect(stale),
        output_has_error: output =~ "error",
        after_error_label: Demo.Counter.label(),
        after_error_current: Totem.current().version == hot.version,
        on_disk_v2: File.read!("lib/demo/counter.ex") =~ ~s("v2"),
        source: hd(Totem.versions()).source
      }
      """)

    assert result["first"] == "found"
    assert result["hot"] == "hot"
    assert result["label"] == "v2"
    assert result["count"] == 2
    assert result["same_pid"]
    assert result["stale"] =~ "conflict"
    assert result["output_has_error"]
    assert result["after_error_label"] == "v2"
    assert result["after_error_current"]
    assert result["on_disk_v2"]
    assert result["source"] == "test"
  end

  test "a config change restarts the app inside the node; mix.exs waits for a restart", %{
    dir: dir
  } do
    result =
      run!(dir, """
      Demo.Counter.bump()
      pid = Process.whereis(Demo.Counter)
      base = Totem.current().version
      config = ~s(import Config\\nconfig :demo, greeting: "hi"\\n)
      {:ok, warm} = Totem.apply(%{base: base, files: [{"config/config.exs", config}]})

      mix = File.read!("mix.exs") <> "\\n# changed\\n"
      {:ok, cold} = Totem.apply(%{base: warm.version, files: [{"mix.exs", mix}]})

      %{
        warm: warm.mode,
        greeting: Demo.Counter.greeting(),
        count: Demo.Counter.count(),
        new_pid: Process.whereis(Demo.Counter) != pid,
        cold: cold.mode,
        cold_status: hd(Totem.versions()).status
      }
      """)

    assert result["warm"] == "warm"
    assert result["greeting"] == "hi"
    assert result["count"] == 0
    assert result["new_pid"]
    assert result["cold"] == "cold"
    assert result["cold_status"] == "restart_required"

    # Booting with it is the restart it waited for.
    assert run!(dir, "%{status: Totem.current().status}") == %{"status" => "loaded"}
  end

  test "edits on disk, deletes, rollback and the archive", %{dir: dir} do
    result =
      run!(dir, """
      base = Totem.current().version
      extra = "defmodule Demo.Extra do\\n  def hi, do: :hi\\nend\\n"
      {:ok, added} = Totem.apply(%{base: base, files: [{"lib/demo/extra.ex", extra}]})
      loaded = Code.ensure_loaded?(Demo.Extra)

      {:ok, deleted} = Totem.apply(%{base: added.version, files: [{"lib/demo/extra.ex", :deleted}]})
      gone = not Code.ensure_loaded?(Demo.Extra)

      File.write!("lib/demo/notes.ex", "# by hand\\n")
      found = Totem.current()

      {:ok, back} = Totem.rollback(added.version)
      back_loaded = Code.ensure_loaded?(Demo.Extra)

      {:ok, files} = :erl_tar.extract({:binary, Totem.archive()}, [:memory, :compressed])
      names = Enum.map(files, fn {name, _} -> to_string(name) end)

      %{
        loaded: loaded,
        gone: gone,
        found: [found.mode, found.version == deleted.version + 1],
        back: [back.mode, back_loaded, File.exists?("lib/demo/notes.ex")],
        names: Enum.sort(names),
        read: Totem.read("lib/demo/extra.ex") == {:ok, extra},
        bad: inspect(Totem.apply(%{base: back.version, files: [{"../x.ex", "x"}]}))
      }
      """)

    assert result["loaded"]
    assert result["gone"]
    assert result["found"] == ["found", true]
    # Rolling back to "added" drops the hand-made file too: it wasn't there then.
    assert result["back"] == ["hot", true, false]

    assert result["names"] ==
             ~w(config/config.exs lib/demo/application.ex lib/demo/counter.ex lib/demo/extra.ex mix.exs)

    assert result["read"]
    assert result["bad"] =~ "bad_path"
  end
end
