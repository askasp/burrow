defmodule Peon.StoreTest do
  use Peon.DataCase, async: false

  alias Peon.{Code, Store}

  @human %{kind: :human, id: "aksel"}
  @ai %{kind: :ai, id: "conv-1"}

  setup %{tmp_dir: dir} do
    write(dir, "mix.exs", "defmodule Saunas.MixProject do end")

    write(
      dir,
      "lib/saunas/bookings.ex",
      "defmodule Saunas.Bookings do\n  def price, do: 100\nend"
    )

    write(dir, "lib/saunas/rooms.ex", "defmodule Saunas.Rooms do\n  def all, do: []\nend")
    write(dir, "priv/repo/migrations/20260101_create_bookings.exs", "create table(:bookings)")
    write(dir, "_build/dev/junk", "x")
    write(dir, "saunas_dev.db", "x")
    write(dir, ".peonignore", "tmp/\n")
    write(dir, "tmp/cache", "x")

    {:ok, import} = Store.import_dir(dir, "saunas", "Saunas", @human)
    %{import: import}
  end

  @moduletag :tmp_dir

  test "import stores the tree without ignored files and points main at it", %{import: cs} do
    assert {:ok, %{id: id}} = Code.resolve("main")
    assert id == cs.id

    assert Code.tree(cs.id) |> Map.keys() |> Enum.sort() == [
             ".peonignore",
             "lib/saunas/bookings.ex",
             "lib/saunas/rooms.ex",
             "mix.exs",
             "priv/repo/migrations/20260101_create_bookings.exs"
           ]

    assert {:ok, "defmodule Saunas.MixProject do end"} = Code.file("mix.exs", "main")
    assert {:error, {:invalid, _}} = Store.import_dir("/tmp", "x", "x", @human)
  end

  test "submit, read back, search, history, diff", %{import: base} do
    {:ok, cs} = submit(base.id, [%{"path" => "lib/saunas/bookings.ex", "content" => price(200)}])

    assert cs.parent_id == base.id
    assert cs.status == "proposed"
    assert cs.flags["restart_required"] == false
    assert {:ok, content} = Code.file("lib/saunas/bookings.ex", cs.id)
    assert content =~ "200"

    assert {:ok, [%{path: "lib/saunas/bookings.ex", line: 2}]} = Code.search("price", cs.id)
    assert {:ok, [_, _]} = Code.search(~S"def \w+,", cs.id, regex: true)
    assert Enum.map(Code.history("lib/saunas/bookings.ex"), & &1.id) == [cs.id, base.id]

    assert {:ok, [%{path: "lib/saunas/bookings.ex", status: "modified", diff: diff}]} =
             Code.diff(base.id, cs.id)

    assert diff =~ "-  def price, do: 100"
    assert diff =~ "+  def price, do: 200"
  end

  test "submit rejects no-ops, bad paths and policy violations with reasons", %{import: base} do
    assert {:error, {:invalid, "no changes against main"}} =
             submit(base.id, [
               %{"path" => "mix.exs", "content" => "defmodule Saunas.MixProject do end"}
             ])

    assert {:error, {:invalid, "invalid path: " <> _}} =
             submit(base.id, [%{"path" => "../etc/passwd", "content" => "x"}])

    assert {:error, {:invalid, _}} = submit(base.id, [%{"path" => "_build/x", "content" => "x"}])

    assert {:error, {:policy, [%{rule: :forbidden_path}]}} =
             submit(base.id, [%{"path" => "config/runtime.exs", "content" => "x"}])

    assert {:error, {:policy, [%{rule: :edited_migration}]}} =
             submit(base.id, [
               %{"path" => "priv/repo/migrations/20260101_create_bookings.exs", "content" => "y"}
             ])
  end

  test "a stale parent rebases when paths don't overlap and conflicts when they do", %{
    import: base
  } do
    {:ok, a} = submit(base.id, [%{"path" => "lib/saunas/bookings.ex", "content" => price(200)}])
    pass_and_merge(a)

    {:ok, b} =
      submit(base.id, [
        %{"path" => "lib/saunas/rooms.ex", "content" => "defmodule Saunas.Rooms do end"}
      ])

    assert b.parent_id == a.id
    assert Code.tree(b.id)["lib/saunas/bookings.ex"] == Code.tree(a.id)["lib/saunas/bookings.ex"]

    assert {:error, {:conflict, ["lib/saunas/bookings.ex"]}} =
             submit(base.id, [%{"path" => "lib/saunas/bookings.ex", "content" => price(300)}])
  end

  test "land puts a passed changeset on main, rebasing it onto main's tip", %{import: base} do
    {:ok, a} = submit(base.id, [%{"path" => "lib/saunas/bookings.ex", "content" => price(200)}])

    {:ok, b} =
      Store.submit(%{
        parent: base.id,
        intent: "rooms",
        files: [%{"path" => "lib/saunas/rooms.ex", "content" => "defmodule Saunas.Rooms do end"}],
        author: @ai,
        conversation_id: "chat-b"
      })

    {:ok, c} = submit(base.id, [%{"path" => "lib/saunas/bookings.ex", "content" => price(300)}])

    assert {:error, {:rejected, "changeset " <> _}} = Store.land(a.id, "peon")

    Store.subscribe()
    assert {:ok, landed_a} = pass_and_merge(a)
    assert landed_a.id == a.id
    assert_receive {:ref_moved, "main", id, _} when id == a.id

    # Other open changesets are left alone when main moves...
    assert {:ok, %{status: "proposed"}} = Code.changeset(b.id)

    # ...and rebased onto the tip when they land.
    {:ok, _} = Store.set_status(b.id, "passed", %{"steps" => []})
    assert {:ok, landed_b} = Store.land(b.id, "peon")
    assert landed_b.parent_id == a.id
    assert landed_b.rebased_from_id == b.id
    assert landed_b.conversation_id == "chat-b"
    assert landed_b.status == "passed"
    assert {:ok, %{status: "superseded"}} = Code.changeset(b.id)
    assert Code.ref("main").changeset_id == landed_b.id

    assert Code.tree(landed_b.id)["lib/saunas/bookings.ex"] ==
             Code.tree(a.id)["lib/saunas/bookings.ex"]

    # Overlapping paths conflict.
    {:ok, _} = Store.set_status(c.id, "passed", %{"steps" => []})
    assert {:error, {:conflict, ["lib/saunas/bookings.ex"]}} = Store.land(c.id, "peon")
    assert {:error, {:rejected, "already on main"}} = Store.land(a.id, "peon")
  end

  test "set_verify records main's test result", %{import: base} do
    Store.subscribe()
    assert {:ok, cs} = Store.set_verify(base.id, %{"status" => "failed", "steps" => []})
    assert cs.verify["status"] == "failed"
    assert_receive {:verified, id, "failed"} when id == base.id
  end

  test "ref rules: CAS, passed-only main, staging on main, prod approval", %{import: base} do
    {:ok, a} = submit(base.id, [%{"path" => "lib/saunas/bookings.ex", "content" => price(200)}])

    assert {:error, {:rejected, "changeset " <> _}} = Store.move_ref("main", a.id, 1, "aksel")
    assert {:error, {:rejected, _}} = Store.move_ref("staging", a.id, 0, "aksel")

    pass_and_merge(a)
    assert {:ok, %{version: 1}} = Store.move_ref("staging", a.id, 0, "aksel")
    assert {:error, {:stale, 1}} = Store.move_ref("staging", a.id, 0, "aksel")

    assert {:error, {:rejected, "moving prod requires" <> _}} =
             Store.move_ref("prod", a.id, 0, "aksel")

    assert {:ok, _} = Store.move_ref("prod", a.id, 0, "aksel", approved_by: "aksel")

    assert {:error, {:invalid, _}} = Store.move_ref("preview/x", a.id, 0, "aksel")
    assert Repo.aggregate(Peon.Store.Event, :count) == 4
  end

  test "destructive migrations need a human approval that survives to the ref move", %{
    import: base
  } do
    migration = [
      %{"path" => "priv/repo/migrations/20260201_drop.exs", "content" => "remove :notes"}
    ]

    assert {:error, {:policy, [%{rule: :destructive_migration}]}} = submit(base.id, migration)

    {:ok, cs} =
      Store.submit(%{
        parent: base.id,
        intent: "drop notes",
        files: migration,
        author: @human,
        approve_destructive: true
      })

    assert cs.flags["approved_destructive"]
    pass_and_merge(cs)
  end

  defp submit(parent, files, author \\ @ai),
    do: Store.submit(%{parent: parent, intent: "test change", files: files, author: author})

  defp pass_and_merge(cs) do
    {:ok, _} = Store.set_status(cs.id, "passed", %{"steps" => []})
    {:ok, _} = Store.land(cs.id, "aksel")
  end

  defp price(n), do: "defmodule Saunas.Bookings do\n  def price, do: #{n}\nend"

  defp write(dir, path, content) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
