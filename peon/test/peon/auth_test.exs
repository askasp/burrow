defmodule Peon.AuthTest do
  # The login a new app starts with (Peon.Template): what Bootstrap keeps and
  # what the agent is told. Not async: it sets environment variables.
  use Peon.DataCase, async: false

  alias Peon.{Bootstrap, Secrets, Store, Template}
  alias Peon.Agent.Prompt

  @template Path.expand("../../../template", __DIR__)

  setup do
    on_exit(fn ->
      System.delete_env("PEON_BASIC_AUTH_USERNAME")
      System.delete_env("PEON_BASIC_AUTH_PASSWORD")
    end)
  end

  test "the basic auth login Burrow passed becomes the app's secrets" do
    System.put_env("PEON_BASIC_AUTH_USERNAME", "ada")
    System.put_env("PEON_BASIC_AUTH_PASSWORD", "correct horse")

    assert :ok = Bootstrap.put_basic_auth()

    assert Secrets.env() == %{
             "BASIC_AUTH_USERNAME" => "ada",
             "BASIC_AUTH_PASSWORD" => "correct horse"
           }

    assert Secrets.requested() == []
  end

  test "without a login from Burrow, the owner is asked for it" do
    System.put_env("PEON_BASIC_AUTH_USERNAME", "ada")

    assert :ok = Bootstrap.put_basic_auth()
    assert Secrets.env() == %{"BASIC_AUTH_USERNAME" => "ada"}
    assert [%{name: "BASIC_AUTH_PASSWORD", set?: false}] = Secrets.requested()
  end

  defp instructions_for(auth) do
    {tree, blobs} = Template.instantiate(@template, "sauna", auth)
    {:ok, _} = Store.import_tree(tree, blobs, "sauna", "Sauna", %{kind: :human, id: "burrow"})
    Prompt.instructions()
  end

  describe "the agent's instructions" do
    test "with accounts, mention them" do
      text = instructions_for("accounts")
      assert text =~ "`:login` (accounts)"
      assert text =~ "@current_scope.user"
      assert text =~ "The generated authentication"
    end

    test "without accounts, say there are none" do
      text = instructions_for("basic")
      refute text =~ ":login"
      refute text =~ "The generated authentication"
      assert text =~ "no user accounts"
      assert text =~ "BASIC_AUTH_USERNAME"
    end
  end
end
