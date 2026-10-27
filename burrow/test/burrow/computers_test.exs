defmodule Burrow.ComputersTest do
  use Burrow.DataCase, async: false

  import Burrow.AccountsFixtures

  alias Burrow.Computers
  alias Burrow.Computers.{Computer, Link}

  @hello %{"name" => "laptop", "os" => "darwin", "arch" => "arm64", "version" => "v1"}

  def paired(user) do
    {:ok, pairing} = Computers.start_pairing(@hello)
    {:ok, _} = Computers.approve(user, pairing.user_code)
    {:ok, token, computer} = Computers.claim_token(pairing.device_code)
    {token, computer}
  end

  describe "pairing" do
    test "a computer gets its token once someone approves its code, and only once" do
      user = user_fixture()
      {:ok, pairing} = Computers.start_pairing(@hello)
      assert pairing.user_code =~ ~r/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/

      assert Computers.claim_token(pairing.device_code) == :pending
      assert %Computer{name: "laptop"} = Computers.pending(String.downcase(pairing.user_code))
      assert Computers.list(user.id) == []

      assert {:ok, _} = Computers.approve(user, pairing.user_code)
      assert Computers.pending(pairing.user_code) == nil
      assert {:ok, "bb_" <> _ = token, computer} = Computers.claim_token(pairing.device_code)
      assert Computers.claim_token(pairing.device_code) == {:error, :expired}

      assert Computers.by_token(token).id == computer.id
      assert Computers.by_token("bb_nope") == nil
      assert [%Computer{name: "laptop", user_id: user_id}] = Computers.list(user.id)
      assert user_id == user.id
    end

    test "a refused or expired code gives no token" do
      user = user_fixture()
      {:ok, refused} = Computers.start_pairing(@hello)
      Computers.refuse(refused.user_code)
      assert Computers.claim_token(refused.device_code) == {:error, :expired}

      {:ok, late} = Computers.start_pairing(@hello)

      Repo.update_all(from(c in Computer, where: c.user_code == ^late.user_code),
        set: [pair_expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
      )

      assert Computers.approve(user, late.user_code) == {:error, :expired}
      assert Computers.claim_token(late.device_code) == {:error, :expired}
      assert Computers.claim_token(nil) == {:error, :expired}
    end

    test "a removed computer's token stops working" do
      user = user_fixture()
      {token, computer} = paired(user)
      Computers.remove(computer)
      assert Computers.by_token(token) == nil
      assert Computers.list(user.id) == []
    end
  end

  describe "the link" do
    test "calls go out to the bridge and its replies come back to each caller" do
      user = user_fixture()
      {_token, computer} = paired(user)
      Computers.subscribe(user.id)
      test = self()

      link =
        spawn_link(fn ->
          {:ok, state} = Link.init(computer)

          {:ok, state} =
            Link.handle_in(
              {Jason.encode!(%{
                 type: "hello",
                 os: "darwin",
                 pick: true,
                 folders: [%{path: "/x", write: true}]
               }), opcode: :text},
              state
            )

          send(test, :ready)
          relay(state, test)
        end)

      assert_receive :ready
      assert_receive {:computer, id} when id == computer.id
      assert Computers.online?(computer.id)

      assert [%{folders: [%{"path" => "/x", "write" => true}], can_pick: true}] =
               Computers.list(user.id)

      task = Task.async(fn -> Computers.call(computer.id, "read", %{path: "/x/a"}) end)
      assert_receive {:pushed, %{"type" => "call", "id" => call_id, "method" => "read"}}
      send(link, {:in, %{type: "reply", id: call_id, result: %{content: "hi"}}})
      assert Task.await(task) == {:ok, %{"content" => "hi"}}

      task = Task.async(fn -> Computers.call(computer.id, "write", %{path: "/etc/x"}) end)
      assert_receive {:pushed, %{"id" => call_id}}
      send(link, {:in, %{type: "reply", id: call_id, error: "outside the folders"}})
      assert Task.await(task) == {:error, "outside the folders"}

      task = Task.async(fn -> Computers.call(computer.id, "list", %{}) end)
      assert_receive {:pushed, _}
      send(link, :stop)
      assert Task.await(task) == {:error, :offline}
      assert_receive {:computer, _}
      refute Computers.online?(computer.id)
      assert Computers.call(computer.id, "list") == {:error, :offline}
    end
  end

  # Plays the websocket's part for Link: what it pushes goes to the test,
  # what the test sends comes in as frames.
  defp relay(state, test) do
    receive do
      {:in, message} ->
        {:ok, state} = Link.handle_in({Jason.encode!(message), opcode: :text}, state)
        relay(state, test)

      :stop ->
        Link.terminate(:normal, state)

      message ->
        case Link.handle_info(message, state) do
          {:push, {:text, text}, state} ->
            send(test, {:pushed, Jason.decode!(text)})
            relay(state, test)

          {:ok, state} ->
            relay(state, test)
        end
    end
  end
end
