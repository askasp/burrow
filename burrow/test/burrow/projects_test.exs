defmodule Burrow.ProjectsTest do
  use Burrow.DataCase, async: true

  import Burrow.AccountsFixtures

  alias Burrow.Projects

  test "create assigns a unique slug and its own ports" do
    scope = user_scope_fixture()
    {:ok, a} = Projects.create(scope, %{"name" => "Sauna Booking"})
    {:ok, b} = Projects.create(scope, %{"name" => "Sauna booking!"})

    assert a.slug == "sauna_booking"
    assert b.slug == "sauna_booking_2"
    assert a.port != b.port
    assert a.preview_ports != b.preview_ports
    assert {:error, %Ecto.Changeset{}} = Projects.create(scope, %{"name" => "1"})
  end

  test "projects are only visible to their owner" do
    {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "Mine"})
    other = user_scope_fixture()

    assert Projects.list(other) == []
    assert_raise Ecto.NoResultsError, fn -> Projects.get!(other, project.id) end
  end

  test "the Peon link carries a token Peon can verify with the shared secret" do
    {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "SSO"})
    url = Projects.peon_url(project, "a@b.no")
    [_, token] = String.split(url, "token=")

    assert {:ok, "a@b.no"} =
             Phoenix.Token.verify(Projects.secret(project, "sso"), "peon sso", token, max_age: 60)
  end
end
