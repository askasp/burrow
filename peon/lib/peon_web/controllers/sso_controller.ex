defmodule PeonWeb.SSOController do
  use PeonWeb, :controller

  def show(conn, %{"token" => token} = params) do
    case PeonWeb.Auth.sso_secret() && PeonWeb.Auth.verify(token) do
      {:ok, email} ->
        # Only a chat's path: never a redirect off this Peon.
        to =
          if is_binary(params["to"]) and params["to"] =~ ~r"\A/c/[a-z0-9]+\z",
            do: params["to"],
            else: ~p"/"

        conn
        |> configure_session(renew: true)
        |> put_session(:peon_user, email)
        |> redirect(to: to)

      _ ->
        conn
        |> put_status(401)
        |> text("This sign-in link is invalid or expired. Open the project from Burrow again.")
    end
  end

  def show(conn, _params) do
    conn |> put_status(401) |> text("Open this project from Burrow to sign in.")
  end
end
