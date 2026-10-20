defmodule PeonWeb.Auth do
  @moduledoc """
  Single sign-on from Burrow. Burrow links to `/sso?token=...`, signed with
  the secret it shares with this Peon (`PEON_SSO_SECRET`). Without a secret
  configured (standalone dev), everyone is let in as "dev".
  """

  import Plug.Conn

  @salt "peon sso"

  def sso_secret, do: Application.get_env(:peon, :sso_secret)

  @doc "Verifies a Burrow SSO token and returns the user's email."
  def verify(token) do
    Phoenix.Token.verify(sso_secret(), @salt, token, max_age: 120)
  end

  # Plug: requires a signed-in user unless SSO is disabled.
  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      sso_secret() == nil ->
        put_session(conn, :peon_user, "dev")

      get_session(conn, :peon_user) ->
        conn

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Open this project from Burrow to sign in.")
        |> halt()
    end
  end

  def on_mount(:default, _params, session, socket) do
    case session["peon_user"] do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/sso")}

      user ->
        {:cont, Phoenix.Component.assign(socket, user: user, theme: session["theme"] || "system")}
    end
  end
end
