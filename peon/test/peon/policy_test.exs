defmodule Peon.PolicyTest do
  use ExUnit.Case, async: true

  alias Peon.Policy

  @base %{"priv/repo/migrations/20260101_create_bookings.exs" => "h1", "lib/app.ex" => "h2"}

  test "plain change passes without flags" do
    assert Policy.check([{"lib/app.ex", "defmodule App do end"}], @base) ==
             {:ok, %{restart_required: false, destructive_migrations: []}}
  end

  test "AI may not touch forbidden paths; humans may" do
    files = [{"config/runtime.exs", "import Config"}, {"rel/env.sh", "x"}]

    assert {:error, [%{rule: :forbidden_path}, %{rule: :forbidden_path}]} =
             Policy.check(files, @base)

    assert {:ok, %{restart_required: true}} = Policy.check(files, @base, author: :human)
  end

  test "restart paths are flagged" do
    for path <- [
          "mix.exs",
          "config/dev.exs",
          "lib/saunas/application.ex",
          "lib/saunas_web/endpoint.ex"
        ] do
      assert {:ok, %{restart_required: true}} = Policy.check([{path, "x"}], @base), path
    end

    assert {:ok, %{restart_required: false}} =
             Policy.check([{"lib/saunas/sub/application.ex", "x"}], @base)
  end

  test "existing migrations cannot be edited or deleted, even by humans" do
    path = "priv/repo/migrations/20260101_create_bookings.exs"

    assert {:error, [%{rule: :edited_migration}]} =
             Policy.check([{path, "x"}], @base, author: :human)

    assert {:error, [%{rule: :edited_migration}]} = Policy.check([{path, :deleted}], @base)
  end

  test "destructive new migrations need human approval" do
    path = "priv/repo/migrations/20260201_drop_x.exs"
    content = "alter table(:bookings) do\n  remove :notes\nend"

    assert {:error, [%{rule: :destructive_migration, path: ^path}]} =
             Policy.check([{path, content}], @base)

    assert {:error, _} =
             Policy.check([{path, content}], @base, author: :ai, approve_destructive: true)

    assert {:ok, %{destructive_migrations: [^path]}} =
             Policy.check([{path, content}], @base, author: :human, approve_destructive: true)

    additive = "alter table(:bookings) do\n  add :notes, :string\nend"
    assert {:ok, %{destructive_migrations: []}} = Policy.check([{path, additive}], @base)
  end

  test "secrets are rejected" do
    for content <- [
          "key = \"sk_live_abcdefghijklmnop\"",
          "-----BEGIN RSA PRIVATE KEY-----",
          "AKIAABCDEFGHIJKLMNOP"
        ] do
      assert {:error, [%{rule: :secret}]} = Policy.check([{"lib/app.ex", content}], @base),
             content
    end
  end
end
