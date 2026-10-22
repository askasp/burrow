defmodule BurrowWeb.BasicAuth do
  @moduledoc """
  The whole site behind one username and password, before Burrow's own
  login, when `:basic_auth` is set (BURROW_BASIC_AUTH_USERNAME and
  BURROW_BASIC_AUTH_PASSWORD). Static files stay open, and so do what
  browsers fetch without credentials: boards in their sandboxed frames
  (their URL's signed token says which chat) and the manifest.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["design" | _]} = conn, _opts), do: conn
  def call(%Plug.Conn{path_info: ["manifest.webmanifest"]} = conn, _opts), do: conn

  def call(conn, _opts) do
    case Application.get_env(:burrow, :basic_auth) do
      nil -> conn
      login -> Plug.BasicAuth.basic_auth(conn, Keyword.put(login, :realm, "Burrow"))
    end
  end
end
