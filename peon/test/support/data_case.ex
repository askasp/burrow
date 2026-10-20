defmodule Peon.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Peon.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Peon.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Peon.DataCase
    end
  end

  setup tags do
    Peon.DataCase.setup_sandbox(tags)
    instance = Peon.DataCase.put_instance()
    store = start_supervised!({Peon.Store, instance})
    Ecto.Adapters.SQL.Sandbox.allow(Peon.Repo, self(), store)

    start_supervised!(
      {DynamicSupervisor, name: Peon.Instance.via(instance, :chats), strategy: :one_for_one}
    )

    %{instance: instance}
  end

  @doc """
  Makes the test process work for a test instance on `Peon.Repo`, with
  `changes` (e.g. `data_dir: dir`), and returns it.
  """
  def put_instance(changes \\ []) do
    base =
      Peon.Instance.current() ||
        %Peon.Instance{
          id: "test-#{System.unique_integer([:positive])}",
          slug: "test_app",
          name: "Test App",
          data_dir:
            Path.join(System.tmp_dir!(), "peon-test-#{System.unique_integer([:positive])}"),
          secret: "test-secret-0123456789-0123456789",
          opencode_model: "openai/gpt-test",
          db: Peon.Repo
        }

    Peon.Instance.put(struct!(base, changes))
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Peon.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
