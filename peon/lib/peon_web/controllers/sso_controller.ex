defmodule PeonWeb.SSOController do
  use PeonWeb, :controller

  def show(conn, %{"token" => token}) do
    case PeonWeb.Auth.sso_secret() && PeonWeb.Auth.verify(token) do
      {:ok, email} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:peon_user, email)
        |> redirect(to: ~p"/")

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
