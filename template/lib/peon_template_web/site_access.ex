defmodule PeonTemplateWeb.SiteAccess do
  @moduledoc """
  Enforces `PeonTemplate.SiteAccess.mode/0`:

    * `require_site_password/2`, in the browser pipeline: with
      `:shared_password`, every page asks for the password first (`/unlock`);
      with `:basic_auth`, the browser asks for the username and password.
    * `require_app_access/2` and `on_mount(:app, ...)`, on the app's pages
      (the router's `:app` scope): the mode's rule for their controllers and
      LiveViews.

  The dev preview skips the password (`:enforce_site_password` is false in
  dev), so pages can be checked there; staging and prod ask for it.
  """

  use PeonTemplateWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias PeonTemplate.SiteAccess
  # peon:if-accounts
  alias PeonTemplateWeb.UserAuth
  # peon:end

  @session_key "site_password"
  @realm "This site"

  @doc "Plug: keeps visitors out until they gave the shared password or the basic auth login."
  def require_site_password(conn, _opts), do: check_site_password(conn, SiteAccess.mode())

  @doc false
  def check_site_password(conn, :shared_password) do
    if not enforced?() or conn.request_path == ~p"/unlock" or
         unlocked?(get_session(conn), :shared_password) do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/unlock")
      |> halt()
    end
  end

  def check_site_password(conn, :basic_auth) do
    cond do
      not enforced?() ->
        conn

      valid_basic_auth?(Plug.BasicAuth.parse_basic_auth(conn)) ->
        # Remembered for the LiveView socket, which on_mount checks.
        if unlocked?(get_session(conn), :basic_auth),
          do: conn,
          else: put_session(conn, @session_key, digest(key(:basic_auth)))

      true ->
        conn |> Plug.BasicAuth.request_basic_auth(realm: @realm) |> halt()
    end
  end

  def check_site_password(conn, _mode), do: conn

  @doc "Plug for the app's controller routes; the rules of `on_mount/4`."
  def require_app_access(conn, opts), do: check_app_access(conn, opts, SiteAccess.mode())

  @doc false
  # peon:if-accounts
  def check_app_access(conn, opts, :login), do: UserAuth.require_authenticated_user(conn, opts)
  # peon:end
  # peon:if-burrow
  def check_app_access(conn, opts, :burrow), do: UserAuth.require_authenticated_user(conn, opts)
  # peon:end
  def check_app_access(conn, _opts, _mode), do: conn

  @doc "`on_mount` for the `:app` live_session: the same rules for LiveViews."
  def on_mount(:app, params, session, socket),
    do: on_mount({:app, SiteAccess.mode()}, params, session, socket)

  # peon:if-accounts
  def on_mount({:app, :login}, params, session, socket),
    do: UserAuth.on_mount(:require_authenticated, params, session, socket)

  # peon:end
  # peon:if-burrow
  def on_mount({:app, :burrow}, params, session, socket),
    do: UserAuth.on_mount(:require_authenticated, params, session, socket)

  # peon:end
  def on_mount({:app, mode}, _params, session, socket)
      when mode in [:shared_password, :basic_auth] do
    cond do
      not enforced?() or unlocked?(session, mode) -> {:cont, socket}
      mode == :shared_password -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/unlock")}
      # A full page load, so the browser asks for the login again.
      true -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  def on_mount({:app, :public}, _params, _session, socket), do: {:cont, socket}

  @doc "The shared password, or nil while the owner hasn't set `SITE_PASSWORD`."
  def password, do: env("SITE_PASSWORD")

  @doc """
  The basic auth login, `{username, password}`, or nil while the owner hasn't
  set both `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD`.
  """
  def basic_auth do
    with user when user != nil <- env("BASIC_AUTH_USERNAME"),
         pw when pw != nil <- env("BASIC_AUTH_PASSWORD"),
         do: {user, pw}
  end

  def valid_password?(given) when is_binary(given) do
    pw = password()
    pw != nil and Plug.Crypto.secure_compare(digest(given), digest(pw))
  end

  def valid_password?(_given), do: false

  @doc false
  def valid_basic_auth?({given_user, given_pw}) do
    case basic_auth() do
      {user, pw} ->
        # Both compared, so the time taken doesn't tell which one was wrong.
        user_ok? = Plug.Crypto.secure_compare(digest(given_user), digest(user))
        pw_ok? = Plug.Crypto.secure_compare(digest(given_pw), digest(pw))
        user_ok? and pw_ok?

      nil ->
        false
    end
  end

  def valid_basic_auth?(_given), do: false

  @doc "Remembers in the session that the password was entered."
  def unlock(conn), do: put_session(conn, @session_key, digest(password()))

  @doc "The session keys that keep the site unlocked (kept across log in and log out)."
  def session_keys, do: [@session_key]

  # What unlocks the site in `mode`, or nil while the owner hasn't set it.
  defp key(:shared_password), do: password()

  defp key(:basic_auth) do
    with {user, pw} <- basic_auth(), do: user <> ":" <> pw
  end

  # The session holds a keyed digest of the password, so changing the
  # password locks everyone out again.
  defp unlocked?(session, mode) do
    key = key(mode)
    stored = session[@session_key]
    key != nil and is_binary(stored) and Plug.Crypto.secure_compare(stored, digest(key))
  end

  defp digest(pw) do
    secret = PeonTemplateWeb.Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, secret, pw) |> Base.encode64()
  end

  defp env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  defp enforced?, do: Application.get_env(:peon_template, :enforce_site_password, true)

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :site_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn
end
