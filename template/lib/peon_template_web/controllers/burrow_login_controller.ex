# peon:burrow-only: Peon puts this file only in internal apps, where Burrow logs people in.
defmodule PeonTemplateWeb.BurrowLoginController do
  @moduledoc """
  This app is internal: it is seen only in Burrow, and people log in to
  Burrow, not here. Burrow sends them to `/burrow/login` with a token it
  signed with the app's key (the `BURROW_LOGIN_SECRET` Burrow gives the app),
  good for a minute: their email and whether they are an admin. They get an
  account here the first time (`PeonTemplate.Accounts.burrow_user!/2`).

  Someone who isn't logged in goes to Burrow (`url/1`), which logs them in
  and sends them back.
  """
  use PeonTemplateWeb, :controller

  alias PeonTemplate.Accounts
  alias PeonTemplateWeb.UserAuth

  @salt "burrow login"
  @max_age 60

  def create(conn, %{"token" => token} = params) do
    with secret when is_binary(secret) <- env("BURROW_LOGIN_SECRET"),
         {:ok, %{"email" => email, "admin" => admin?}} <-
           Plug.Crypto.verify(secret, @salt, token, max_age: @max_age) do
      conn
      |> put_session(:user_return_to, local(params["return_to"]))
      |> UserAuth.log_in_user(Accounts.burrow_user!(email, admin?))
    else
      _ -> elsewhere(conn)
    end
  end

  def create(conn, _params), do: elsewhere(conn)

  @doc """
  Burrow's page that logs people in to this app and sends them back to
  `path`; without Burrow (tests, a bare preview) this app's own page saying
  so.
  """
  def url(path) do
    case {env("BURROW_URL"), env("BURROW_APP")} do
      {nil, _app} -> ~p"/burrow/login"
      {_url, nil} -> ~p"/burrow/login"
      {url, app} -> url <> "/projects/#{app}/app?" <> URI.encode_query(to: local(path))
    end
  end

  defp elsewhere(conn) do
    conn
    |> put_status(403)
    |> text("This app opens in Burrow. Open it from Burrow's Apps to log in.")
  end

  # Only this app's own pages: a path, never "//elsewhere".
  defp local("/" <> rest = path),
    do: if(String.starts_with?(rest, ["/", "\\"]), do: "/", else: path)

  defp local(_path), do: "/"

  defp env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end
end
