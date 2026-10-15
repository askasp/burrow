defmodule Peon.ShipTest do
  use Peon.DataCase, async: false

  alias Peon.{Code, Env, Incidents, Project, Ship, Store}

  @moduletag :tmp_dir
  @ai %{kind: :ai, id: "chat-1"}

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib/app_web"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    File.write!(Path.join(dir, "lib/app.ex"), "defmodule App do end")
    File.write!(Path.join(dir, "lib/app_web/page.ex"), "defmodule AppWeb.Page do end")
    {:ok, base} = Store.import_dir(dir, "app", "App", %{kind: :human, id: "aksel"})
    set_settings(%{"auto_fix" => false})
    %{base: base}
  end

  test "passed AI changes land by themselves unless they touch review paths", %{base: base} do
    {:ok, ok} = passed(base.id, "lib/app.ex", "defmodule App do def x, do: 1 end")
    assert Ship.review_reasons(ok) == []
    assert {:landed, id} = Ship.after_checks(ok)
    assert Code.ref("main").changeset_id == id

    {:ok, auth} = passed(id, "lib/app_web/user_auth.ex", "defmodule AppWeb.UserAuth do end")
    assert Ship.review_reasons(auth) == []
    assert {:landed, id} = Ship.after_checks(auth)

    {:ok, deps} = passed(id, "mix.exs", "defmodule App.MixProject do @x 1 end")
    assert {:held, ["it changes mix.exs"]} = Ship.after_checks(deps)

    set_settings(%{"auto_land" => false, "auto_fix" => false})
    {:ok, any} = passed(id, "lib/app_web/page.ex", "defmodule AppWeb.Page do @x 1 end")
    assert {:held, ["auto-landing is off for this project"]} = Ship.after_checks(any)
  end

  test "revert submits the inverse of a changeset", %{base: base} do
    {:ok, cs} = passed(base.id, "lib/app.ex", "defmodule App do def x, do: 1 end")
    {:landed, id} = Ship.after_checks(cs)

    assert {:ok, revert} = Ship.revert(id, "aksel")
    assert revert.author_kind == "human"
    assert revert.intent =~ "Revert ##{id}"
    assert Code.tree(revert.id)["lib/app.ex"] == Code.tree(base.id)["lib/app.ex"]
    assert Ship.review_reasons(revert) == []
  end

  test "incidents group by fingerprint, reopen, and resolve when their fix deploys", %{
    base: base
  } do
    error = %{
      "kind" => "ArgumentError",
      "message" => "bad id 42",
      "frame" => "lib/app_web/page.ex:3",
      "text" => "** (ArgumentError) bad id 42",
      "stacktrace" => "    lib/app_web/page.ex:3: AppWeb.Page.show/2"
    }

    first = Incidents.report("staging", error, base.id)
    assert first.status == "open"
    assert first.title == "ArgumentError: bad id 42 (lib/app_web/page.ex:3)"
    assert first.detail =~ "page.ex:3"

    again = Incidents.report("staging", %{error | "message" => "bad id 7"}, base.id)
    assert again.id == first.id
    assert again.count == 2

    # Without a frame, messages that differ only in numbers and pids group too.
    no_frame = Map.delete(error, "frame")

    assert Incidents.fingerprint(no_frame) ==
             Incidents.fingerprint(%{no_frame | "message" => "bad id 9"})

    # A fix chat's changeset reaching the env resolves the incident.
    fixing = first |> Ecto.Changeset.change(status: "fixing", chat_id: "fix-1") |> Repo.update!()

    {:ok, fix} =
      Store.submit(%{
        parent: base.id,
        intent: "fix",
        files: [%{"path" => "lib/app_web/page.ex", "content" => "defmodule AppWeb.Page do end\n"}],
        author: @ai,
        conversation_id: "fix-1"
      })

    {:ok, _} = Store.set_status(fix.id, "passed", %{"steps" => []})
    {:ok, landed} = Store.land(fix.id, "peon")
    :ok = Incidents.deployed("staging", landed.id)
    assert Incidents.get(fixing.id).status == "resolved"

    # Seen again after that: reopened.
    reopened = Incidents.report("staging", error, landed.id)
    assert reopened.id == first.id
    assert reopened.status == "open"
    assert reopened.chat_id == nil
  end

  test "an incident whose fix chat fails goes back to open", %{base: base} do
    incident = Incidents.report("prod", %{"message" => "boom"}, base.id)
    fixing = incident |> Ecto.Changeset.change(status: "fixing", chat_id: "c1") |> Repo.update!()

    :ok = Incidents.chat_failed("c1", "This model is not available in your country")
    reopened = Incidents.get(fixing.id)
    assert reopened.status == "open"
    assert reopened.chat_id == "c1"
    assert reopened.detail =~ "Fix chat stopped: This model is not available"
  end

  test "a failed fix chat is asked once more before the incident reopens", %{base: base} do
    Application.put_env(:peon, :fix_retries, 1)
    on_exit(fn -> Application.put_env(:peon, :fix_retries, 0) end)

    incident = Incidents.report("prod", %{"message" => "boom"}, base.id)
    incident |> Ecto.Changeset.change(status: "fixing", chat_id: "c2") |> Repo.update!()

    :ok = Incidents.chat_failed("c2", "provider hiccup")

    assert %{status: "fixing", detail: "Fix chat stopped (asked again): provider hiccup" <> _} =
             Incidents.get(incident.id)

    :ok = Incidents.chat_failed("c2", "provider hiccup")
    assert Incidents.get(incident.id).status == "open"
  end

  test "code-only deploys are hot, restart paths are cold" do
    assert Env.hot?(["lib/app_web/page.ex", "priv/repo/migrations/20261015_add.exs"])
    refute Env.hot?(["lib/app.ex", "mix.exs"])
    refute Env.hot?(["config/config.exs"])
    refute Env.hot?(["lib/app/application.ex"])
    refute Env.hot?(:all)
  end

  defp passed(parent, path, content) do
    {:ok, cs} =
      Store.submit(%{
        parent: parent,
        intent: "change #{path}",
        files: [%{"path" => path, "content" => content}],
        author: @ai,
        conversation_id: "chat-1"
      })

    Store.set_status(cs.id, "passed", %{"steps" => []})
  end

  defp set_settings(settings),
    do: Project.get() |> Ecto.Changeset.change(settings: settings) |> Repo.update!()
end
