# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplate.BackofficeTest do
  use PeonTemplate.DataCase

  import PeonTemplate.AccountsFixtures

  alias PeonTemplate.Backoffice
  alias PeonTemplate.Accounts
  alias PeonTemplate.Accounts.{User, UserToken}

  # A schema with its own changeset, to save through. Without a table, it is
  # not one of the app's schemas.
  defmodule Pet do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :name, :string
      field :kind, Ecto.Enum, values: [:cat, :dog]
    end

    def changeset(pet, attrs) do
      pet |> cast(attrs, [:name, :kind]) |> validate_required([:name])
    end
  end

  describe "schemas" do
    test "are the app's schemas with a table, found by themselves" do
      assert [
               %{name: "Accounts.User", schema: User, source: "users"},
               %{name: "Accounts.UserToken", schema: UserToken, source: "users_tokens"}
             ] = Backoffice.schemas()

      assert Backoffice.schema("Accounts.User").schema == User
      refute Backoffice.schema("Pet")
      refute Backoffice.schema("Elixir.File")
    end

    test "never show or set redacted fields" do
      assert {:email, :string} in Backoffice.fields(User)
      refute Keyword.has_key?(Backoffice.fields(User), :hashed_password)
      refute Keyword.has_key?(Backoffice.fields(UserToken), :token)
    end

    test "set what a form can hold, not the key or the timestamps" do
      assert Keyword.keys(Backoffice.editable(User)) == [:email, :confirmed_at, :admin]

      assert Keyword.keys(Backoffice.editable(UserToken)) ==
               [:context, :sent_to, :authenticated_at, :user_id]

      assert Backoffice.input(:boolean) == "checkbox"
      assert Backoffice.input(Pet.__schema__(:type, :kind)) == "select"
      assert Backoffice.options(Pet, :kind) == [:cat, :dog]
      assert Backoffice.input(:map) == nil
    end
  end

  describe "list/2" do
    test "pages through the rows, the newest first" do
      [a, b, c] = for _ <- 1..3, do: user_fixture()

      first = Backoffice.list(User, per_page: 2)
      assert %{total: 3, page: 1, pages: 2} = first
      assert ids(first) == [c.id, b.id]
      assert ids(Backoffice.list(User, per_page: 2, page: "2")) == [a.id]
      assert %{page: 2} = Backoffice.list(User, per_page: 2, page: "9")
      assert %{page: 1} = Backoffice.list(User, per_page: 2, page: "nope")
    end

    test "searches the text in any case, or an id" do
      # No digits in the emails: an id is searched for in the text too.
      user = user_fixture(email: "Sauna.Fan@example.com")
      _other = user_fixture(email: "other@example.com")

      assert ids(Backoffice.list(User, q: "sauna.fan")) == [user.id]
      assert ids(Backoffice.list(User, q: to_string(user.id))) == [user.id]
      assert ids(Backoffice.list(User, q: "nobody")) == []
    end

    test "filters by a field, and ignores fields it doesn't show" do
      user = user_fixture()
      Accounts.generate_user_session_token(user)
      Accounts.generate_user_session_token(user_fixture())

      assert [%{user_id: id}] =
               Backoffice.list(UserToken, filter: %{"user_id" => "#{user.id}"}).rows

      assert id == user.id
      assert Backoffice.list(UserToken, filter: %{"token" => "x"}).total == 2
      assert Backoffice.list(UserToken, filter: %{"user_id" => "abc"}).total == 0
    end
  end

  describe "a row" do
    test "is found by its id as text" do
      user = user_fixture()
      assert Backoffice.get(User, to_string(user.id)).id == user.id
      refute Backoffice.get(User, "abc")
      refute Backoffice.get(User, "0")
    end

    test "links to the row it belongs to and the rows that point at it" do
      user = user_fixture()
      Accounts.generate_user_session_token(user)
      [token | _] = Repo.all_by(UserToken, user_id: user.id)

      assert [%{name: :user, kind: :parent, schema: "Accounts.User", id: id}] =
               Backoffice.links(UserToken, token)

      assert id == user.id
    end

    test "shows as text" do
      assert Backoffice.text(nil) == nil
      assert Backoffice.text(true) == "yes"
      assert Backoffice.text(~U[2026-10-25 10:30:15Z]) == "2026-10-25 10:30:15 UTC"
      assert Backoffice.text(<<0, 255>>) == "(2 bytes)"
      assert Backoffice.text(%{"a" => 1}) == ~s(%{"a" => 1})
    end
  end

  describe "save/3" do
    test "adds and edits rows with the fields cast as they are" do
      {:ok, user} =
        Backoffice.save(User, %User{}, %{"email" => "new@example.com", "admin" => "true"})

      assert user.admin

      {:ok, user} = Backoffice.save(User, user, %{"email" => "renamed@example.com"})
      assert Repo.get!(User, user.id).email == "renamed@example.com"
    end

    test "turns a unique index into the field's error" do
      user = user_fixture()
      {:error, changeset} = Backoffice.save(User, %User{}, %{"email" => user.email})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "turns what the database refuses into an error" do
      {:error, changeset} = Backoffice.save(User, %User{}, %{})
      assert [refused] = errors_on(changeset).base
      assert refused =~ "The database refused it"

      {:error, changeset} =
        Backoffice.save(UserToken, %UserToken{token: "t"}, %{"context" => "x", "user_id" => "0"})

      assert errors_on(changeset).base != []
    end

    test "deletes a row, and says when it is already gone" do
      user = user_fixture()
      Accounts.generate_user_session_token(user)
      [token | _] = Repo.all_by(UserToken, user_id: user.id)

      assert {:ok, _} = Backoffice.delete(token)
      refute Repo.get(UserToken, token.id)
      assert {:error, message} = Backoffice.delete(token)
      assert message =~ "stale"
    end

    test "uses the schema's own changeset/2 when it has one" do
      changeset = Backoffice.change(Pet, %Pet{}, %{"kind" => "cat"})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert changeset.changes.kind == :cat
    end
  end

  defp ids(page), do: Enum.map(page.rows, & &1.id)
end
