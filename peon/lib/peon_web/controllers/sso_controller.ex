defmodule PeonWeb.SSOController do
  use PeonWeb, :controller

  def show(conn, %{"token" => token} = params) do
    case PeonWeb.Auth.sso_secret() && PeonWeb.Auth.verify(token) do
      {:ok, email} ->
        # Only a chat's path: never a redirect off this Peon.
        to =
          if is_binary(params["to"]) and params["to"] =~ ~r"\A/c/[a-z0-9]+\z",
            do: PeonWeb.Endpoint.path(params["to"]),
            else: ~p"/"

        conn
        |> configure_session(renew: true)
        |> put_session(:peon_user, email)
        |> put_theme(params["theme"])
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

  # The user's theme from Burrow, for `<html data-theme>`.
  defp put_theme(conn, theme) when theme in ~w(system light dark),
    do: put_session(conn, :theme, theme)

  defp put_theme(conn, _theme), do: conn

  @doc "The workspace keeps the theme for the next page load, when it changed meanwhile."
  def theme(conn, %{"theme" => theme}) when theme in ~w(system light dark),
    do: conn |> put_session(:theme, theme) |> send_resp(204, "")

  def theme(conn, _params), do: send_resp(conn, 422, "")
end
