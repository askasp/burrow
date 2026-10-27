# peon:burrow-only: Peon puts this file only in internal apps, where Burrow logs people in.
defmodule PeonTemplateWeb.BurrowLoginControllerTest do
  # Not async: the tests set the BURROW_* environment variables.
  use PeonTemplateWeb.ConnCase, async: false

  alias PeonTemplate.Accounts
  alias PeonTemplateWeb.{BurrowLoginController, UserAuth}

  @secret "the key Burrow gave this app"
  @env %{
    "BURROW_LOGIN_SECRET" => @secret,
    "BURROW_URL" => "https://burrow.example",
    "BURROW_APP" => "7"
  }

  setup do
    previous = Map.new(@env, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(@env)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  defp token(claims, opts \\ []), do: Plug.Crypto.sign(@secret, "burrow login", claims, opts)

  defp log_in(conn, claims, params \\ []),
    do: get(conn, ~p"/burrow/login?#{[token: token(claims)] ++ params}")

  test "Burrow's token logs the person in, with a new account, and goes on", %{conn: conn} do
    conn = log_in(conn, %{"email" => "ada@example.com", "admin" => true}, return_to: "/x?y=1")

    assert redirected_to(conn) == "/x?y=1"
    assert get_session(conn, :user_token)

    assert %{admin: true, confirmed_at: %DateTime{}} =
             Accounts.get_user_by_email("ada@example.com")
  end

  test "the next time it is the same account, and Burrow says whether it is an admin",
       %{conn: conn} do
    log_in(conn, %{"email" => "ada@example.com", "admin" => true})
    conn = log_in(build_conn(), %{"email" => "ada@example.com", "admin" => false})

    assert redirected_to(conn) == "/"
    assert %{admin: false} = Accounts.get_user_by_email("ada@example.com")
  end

  test "only goes on to this app's own pages", %{conn: conn} do
    conn =
      log_in(conn, %{"email" => "ada@example.com", "admin" => false}, return_to: "//evil.example")

    assert redirected_to(conn) == "/"
  end

  test "no token, another key's or an old one: nobody is logged in", %{conn: conn} do
    forged =
      Plug.Crypto.sign("another key", "burrow login", %{"email" => "a@b.c", "admin" => true})

    old =
      token(%{"email" => "a@b.c", "admin" => true}, signed_at: System.system_time(:second) - 120)

    for query <- [[], [token: forged], [token: old]] do
      conn = get(conn, ~p"/burrow/login?#{query}")
      assert text_response(conn, 403) =~ "opens in Burrow"
      refute get_session(conn, :user_token)
    end

    refute Accounts.get_user_by_email("a@b.c")
  end

  test "who isn't logged in goes to Burrow, which sends them back" do
    assert BurrowLoginController.url("/x?y=1") ==
             "https://burrow.example/projects/7/app?to=%2Fx%3Fy%3D1"

    assert UserAuth.log_in(:burrow, "/") ==
             [external: "https://burrow.example/projects/7/app?to=%2F"]

    System.delete_env("BURROW_URL")
    assert BurrowLoginController.url("/x") == ~p"/burrow/login"
  end
end
