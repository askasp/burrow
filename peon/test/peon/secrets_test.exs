defmodule Peon.SecretsTest do
  use Peon.DataCase, async: false

  alias Peon.Agent.Tools
  alias Peon.Secrets

  setup do
    Secrets.subscribe()
    :ok
  end

  test "set secrets reach the app's env; the list never shows values" do
    assert :ok = Secrets.put("SLACK_TOKEN", "xoxb-1", "ada@example.com")
    assert_receive {:secrets, [%{name: "SLACK_TOKEN", set?: true}]}

    assert Secrets.env() == %{"SLACK_TOKEN" => "xoxb-1"}
    refute inspect(Secrets.list()) =~ "xoxb-1"

    before = Secrets.fingerprint()
    assert :ok = Secrets.put("SLACK_TOKEN", "xoxb-2", "ada@example.com")
    assert Secrets.fingerprint() != before

    assert :ok = Secrets.delete("SLACK_TOKEN")
    assert Secrets.env() == %{}
  end

  test "names are env var names that Peon doesn't set itself" do
    assert {:error, _} = Secrets.put("slack token", "x", "ada")
    assert {:error, _} = Secrets.put("SECRET_KEY_BASE", "x", "ada")
    assert {:error, _} = Secrets.put("PEON_COOKIE", "x", "ada")
    assert {:error, _} = Secrets.put("SLACK_TOKEN", "", "ada")
    assert Secrets.list() == []
  end

  test "the agent sees names only and can ask for a secret" do
    assert {"No secrets yet." <> _, false} = Tools.call("secrets", %{}, "chat1")

    assert {"Asked the user for SITE_PASSWORD." <> _, false} =
             Tools.call(
               "request_secret",
               %{"name" => "SITE_PASSWORD", "why" => "The password for the site"},
               "chat1"
             )

    assert [%{name: "SITE_PASSWORD", set?: false, chat_id: "chat1"}] = Secrets.requested("chat1")
    assert Secrets.requested("chat2") == []
    assert Secrets.env() == %{}

    assert {text, false} = Tools.call("secrets", %{}, "chat1")
    assert text =~ "SITE_PASSWORD: asked for"

    assert {_, true} =
             Tools.call("request_secret", %{"name" => "PORT", "why" => "nope"}, "chat1")
  end

  test "asking for one that is set says so" do
    :ok = Secrets.put("SLACK_TOKEN", "xoxb-1", "ada")

    assert {"SLACK_TOKEN is already set." <> _, false} =
             Tools.call("request_secret", %{"name" => "SLACK_TOKEN", "why" => "x"}, "chat1")

    assert {text, false} = Tools.call("secrets", %{}, "chat1")
    assert text =~ "SLACK_TOKEN: set"
    refute text =~ "xoxb"
  end
end
