defmodule PeonTemplateWeb.SiteAccess do
  @moduledoc """
  Enforces `PeonTemplate.SiteAccess.mode/0`:

    * `require_site_password/2`, in the browser pipeline: with
      `:shared_password`, every page asks for the password first (`/unlock`).
    * `require_app_access/2` and `on_mount(:app, ...)`, on the app's pages:
      with `:login`, they need a logged-in user.

  The dev preview skips the password (`:enforce_site_password` is false in
  dev), so pages can be checked there; staging and prod ask for it.
  """

  use PeonTemplateWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias PeonTemplate.SiteAccess
  alias PeonTemplateWeb.UserAuth

  @session_key "site_password"

  @doc "Plug: with a shared password, sends visitors who haven't entered it to /unlock."
  def require_site_password(conn, _opts), do: check_site_password(conn, SiteAccess.mode())

  @doc false
  def check_site_password(conn, :shared_password) do
    if not enforced?() or conn.request_path == ~p"/unlock" or unlocked?(get_session(conn)) do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/unlock")
      |> halt()
    end
  end

  def check_site_password(conn, _mode), do: conn

  @doc "Plug for the app's controller routes: with `:login`, requires a logged-in user."
  def require_app_access(conn, opts), do: check_app_access(conn, opts, SiteAccess.mode())

  @doc false
  def check_app_access(conn, opts, :login), do: UserAuth.require_authenticated_user(conn, opts)
  def check_app_access(conn, _opts, _mode), do: conn

  @doc "`on_mount` for the `:app` live_session: the same rules for LiveViews."
  def on_mount(:app, params, session, socket),
    do: on_mount({:app, SiteAccess.mode()}, params, session, socket)

  def on_mount({:app, :login}, params, session, socket),
    do: UserAuth.on_mount(:require_authenticated, params, session, socket)

  def on_mount({:app, :shared_password}, params, session, socket) do
    if not enforced?() or unlocked?(session),
      do: UserAuth.on_mount(:mount_current_scope, params, session, socket),
      else: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/unlock")}
  end

  def on_mount({:app, :public}, params, session, socket),
    do: UserAuth.on_mount(:mount_current_scope, params, session, socket)

  @doc "The shared password, or nil while the owner hasn't set `SITE_PASSWORD`."
  def password do
    case System.get_env("SITE_PASSWORD") do
      pw when pw in [nil, ""] -> nil
      pw -> pw
    end
  end

  def valid_password?(given) when is_binary(given) do
    pw = password()
    pw != nil and Plug.Crypto.secure_compare(digest(given), digest(pw))
  end

  def valid_password?(_given), do: false

  @doc "Remembers in the session that the password was entered."
  def unlock(conn), do: put_session(conn, @session_key, digest(password()))

  @doc "The session keys that keep the site unlocked (kept across log in and log out)."
  def session_keys, do: [@session_key]

  # The session holds a keyed digest of the password, so changing the
  # password locks everyone out again.
  defp unlocked?(session) do
    pw = password()
    stored = session[@session_key]
    pw != nil and is_binary(stored) and Plug.Crypto.secure_compare(stored, digest(pw))
  end

  defp digest(pw) do
    secret = PeonTemplateWeb.Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, secret, pw) |> Base.encode64()
  end

  defp enforced?, do: Application.get_env(:peon_template, :enforce_site_password, true)

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :site_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn
end
