defmodule Burrow.RecordsTest do
  # Chats, secrets and incidents: what Burrow keeps per project.
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{Chats, Incidents, Projects, Secrets}

  setup do
    project = project_fixture()
    Chats.subscribe(project.id)
    %{project: project}
  end

  describe "chats" do
    test "up to four, empty until the first message titles them", %{project: project} do
      chat = Chats.create_empty(project.id, "ada")
      assert_receive {:chat_created, %{id: id}} when id == chat.id
      assert chat.title == "" and chat.started_at == nil

      Chats.started(chat, "  Add   a booking page\nwith a calendar ")
      assert_receive {:chat_started, ^id}

      assert %{title: "Add a booking page with a calendar", started_at: %DateTime{}} =
               Chats.get(id)

      # A later message doesn't retitle it.
      Chats.started(Chats.get(id), "something else")
      assert Chats.get(id).title == "Add a booking page with a calendar"

      # Empty chats don't count, started ones do.
      for _ <- 1..Chats.max(), do: Chats.create_empty(project.id, "ada")
      assert Burrow.Activity.room?(project)
      for _ <- 2..Chats.max(), do: Chats.create(project.id, "t", "ada")
      refute Burrow.Activity.room?(project)
      assert Chats.list(project_fixture().id) == []
    end

    test "a chat is seen by whoever opened it; Peon's by the project's owner", %{
      project: project
    } do
      owner = Repo.get!(Burrow.Accounts.User, project.user_id)
      mate = Burrow.AccountsFixtures.user_fixture()
      peons = Chats.create_empty(project.id, "peon")
      owners = Chats.create_empty(project.id, owner)
      mates = Chats.create_empty(project.id, mate)
      ids = &MapSet.new(Chats.list(project, &1), fn c -> c.id end)

      assert ids.(owner.id) == MapSet.new([peons.id, owners.id])
      assert ids.(mate.id) == MapSet.new([mates.id])
      assert Chats.get(project, mate.id, mates.id)
      refute Chats.get(project, mate.id, owners.id) || Chats.get(project, mate.id, peons.id)
      refute Chats.get(project_fixture(), mate.id, mates.id)

      # Everyone has their own four.
      for _ <- 1..Chats.max(), do: Chats.create(project.id, "t", mate)
      refute Burrow.Activity.room?(project, mate.id)
      assert Burrow.Activity.room?(project, owner.id)
    end

    test "keep running, then delete", %{project: project} do
      chat = Chats.create(project.id, "t", "ada", model: "openai/gpt-x", effort: "high")
      assert {chat.model, chat.effort} == {"openai/gpt-x", "high"}
      Chats.pick_model(chat, "openrouter/anthropic/claude-x", "max")
      assert %{model: "openrouter/anthropic/claude-x", effort: "max"} = Chats.get(chat.id)
      Chats.pick_model(chat, "no model", "")
      assert %{model: nil, effort: nil} = Chats.get(chat.id)
      refute Chats.kept_running?(chat)

      Chats.keep_running(chat, 2)
      assert Chats.kept_running?(Chats.get(chat.id))
      assert [_] = Chats.list_kept_running(project.id)
      Chats.keep_running(chat, nil)
      refute Chats.kept_running?(Chats.get(chat.id))

      Chats.delete(chat)
      assert_receive {:chat_deleted, id} when id == chat.id
      assert Chats.get(chat.id) == nil
    end
  end

  describe "secrets" do
    test "names are checked; values reach the app, never Burrow's own", %{project: project} do
      assert {:error, _} = Secrets.put(project.id, "lower", "x", "ada")
      assert {:error, _} = Secrets.put(project.id, "MIX_ENV", "x", "ada")
      assert {:error, _} = Secrets.put(project.id, "TOTEM_LINK", "x", "ada")
      assert {:error, _} = Secrets.put(project.id, "SLACK_TOKEN", "", "ada")

      :ok = Secrets.put(project.id, "SLACK_TOKEN", "xoxb-1", "ada")
      :ok = Secrets.put(project.id, "GITHUB_TOKEN", "github_pat_x", "ada")
      assert Secrets.env(project.id) == %{"SLACK_TOKEN" => "xoxb-1"}
      assert Secrets.value(project.id, "GITHUB_TOKEN") == "github_pat_x"
      assert Secrets.env(project_fixture().id) == %{}

      fingerprint = Secrets.fingerprint(Secrets.env(project.id))
      :ok = Secrets.put(project.id, "SLACK_TOKEN", "xoxb-2", "ada")
      refute Secrets.fingerprint(Secrets.env(project.id)) == fingerprint
    end

    test "the agent asks; setting it answers the chat that asked", %{project: project} do
      Secrets.subscribe(project.id)
      assert {:ok, :requested} = Secrets.request(project.id, "STRIPE_KEY", "Takes payments", "c1")
      assert_receive {:secrets, [%{name: "STRIPE_KEY", set?: false, chat_id: "c1"}]}

      :ok = Secrets.put(project.id, "STRIPE_KEY", "sk_test_1", "ada")
      assert [%{name: "STRIPE_KEY", set?: true}] = Secrets.list(project.id)
      assert {:ok, :already_set} = Secrets.request(project.id, "STRIPE_KEY", "again", "c2")

      :ok = Secrets.delete(project.id, "STRIPE_KEY")
      assert Secrets.list(project.id) == []
    end
  end

  describe "incidents" do
    @error %{
      "fingerprint" => "f1",
      "kind" => "ArgumentError",
      "message" => "boom",
      "text" => "boom",
      "stacktrace" => "lib/x.ex:1"
    }

    test "errors group by fingerprint; a fix chat is opened while there is room", %{
      project: project
    } do
      Incidents.report(project, "prod", @error, 3)

      assert [%{count: 1, status: "fixing", chat_id: chat_id, change_id: 3} = incident] =
               Incidents.list(project.id)

      assert %{title: "Fix: ArgumentError: boom"} = Chats.get(chat_id)

      Incidents.report(project, "prod", @error, 4)
      assert [%{count: 2, id: id}] = Incidents.list(project.id)
      assert id == incident.id

      # The fix chat stops with an error: with no retries left it goes back to the user.
      Incidents.chat_failed(project.id, chat_id, "no AI login")
      assert %{status: "open", detail: "Fix chat stopped: no AI login" <> _} = Incidents.get(id)

      Incidents.resolve(Incidents.get(id))
      Incidents.report(project, "prod", @error, 5)
      assert %{status: "fixing", count: 3} = Incidents.get(id)
    end

    test "auto-fix off leaves it open; a deployed fix resolves it", %{project: project} do
      history!(project, %{"lib/x.ex" => "x\n"})
      Projects.put_settings(project, %{"auto_fix" => false})

      Incidents.report(project, "prod", @error, 1)
      assert [%{status: "open", chat_id: nil} = incident] = Incidents.list(project.id)

      {:ok, %{chat_id: chat_id}} = Incidents.fix(incident, project, "ada")
      repo = Projects.repo_dir(project)
      {:ok, _} = Totem.Repo.put_draft(repo, chat_id, 1, [{"lib/x.ex", "fixed\n"}])
      {:ok, change} = Totem.Repo.land(repo, chat_id, chat_id)

      Incidents.deployed(project, "prod", change.id - 1)
      assert Incidents.get(incident.id).status == "fixing"
      Incidents.deployed(project, "prod", change.id)
      assert Incidents.get(incident.id).status == "resolved"
    end

    test "deleting the fix chat gives the incident back", %{project: project} do
      Incidents.report(project, "staging", @error, 1)
      [%{chat_id: chat_id, id: id}] = Incidents.list(project.id)
      Incidents.chat_deleted(project.id, chat_id)
      assert %{status: "open", chat_id: nil} = Incidents.get(id)
    end
  end
end
