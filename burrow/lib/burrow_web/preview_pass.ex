defmodule BurrowWeb.PreviewPass do
  @moduledoc """
  Previews and staging, only for people logged in to Burrow, with no second
  login. Their addresses (`:port_url`, e.g. https://peon-<port>.example.com)
  are public, so the router in front of them asks `/previews/auth?port=<port>`
  first (Caddy's `forward_auth`): a prod app is open to everyone, anything else
  needs the pass. That's a cookie for the addresses' whole domain, which Burrow
  gives everyone logged in. It lets them see previews, never logs anyone in to
  Burrow, and the router takes it out before a request reaches the app.

  A preview's own calls between its ports (a frontend's to its API) carry no
  cookies, so a chat's preview addresses also have its key in the host
  (`Burrow.Ports.url/2`, `?key=`), good while the chat runs.

  An internal app's live (`Burrow.Projects.Project.internal?/1`) is only
  for the people who see its project: their pass, not anyone's.

  Without such addresses (plain localhost ports, no router) there is no pass.
  """

  @behaviour Plug

  import Plug.Conn

  @cookie "burrow_preview"
  @salt "preview pass"
  @max_age 30 * 24 * 60 * 60
  # A pass this old is renewed on the next page.
  @renew_age 24 * 60 * 60

  @impl true
  def init(opts), do: opts

  # In the endpoint, ahead of the code reloader: every request to a preview asks.
  @impl true
  def call(%Plug.Conn{path_info: ["previews", "auth"]} = conn, _opts) do
    conn = conn |> fetch_query_params() |> fetch_cookies()
    port = port(conn.query_params["port"])
    pass = verify(conn.cookies[@cookie], @max_age)

    if Burrow.Chat.preview_key?(port, conn.query_params["key"]) or open?(env(port), pass) do
      conn |> send_resp(204, "") |> halt()
    else
      conn
      |> put_resp_header("location", BurrowWeb.Endpoint.url() <> "/users/log-in")
      |> send_resp(302, "")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc "Gives the logged-in user a pass, or a new one once theirs is a day old."
  def put_pass(conn, _opts) do
    with %{user: %{id: id}} <- conn.assigns[:current_scope],
         domain when is_binary(domain) <- domain(),
         false <- verify(conn.cookies[@cookie], @renew_age) == {:ok, id} do
      token = Phoenix.Token.sign(BurrowWeb.Endpoint, @salt, id)
      put_resp_cookie(conn, @cookie, token, options(domain))
    else
      _ -> conn
    end
  end

  @doc "Takes the pass back, as the user logs out."
  def delete_pass(conn) do
    case domain() do
      nil -> conn
      domain -> delete_resp_cookie(conn, @cookie, options(domain))
    end
  end

  defp verify(nil, _max_age), do: :error

  defp verify(token, max_age),
    do: Phoenix.Token.verify(BurrowWeb.Endpoint, @salt, token, max_age: max_age)

  defp options(domain),
    do: [domain: domain, max_age: @max_age, secure: true, http_only: true, same_site: "Lax"]

  defp port(param) do
    case Integer.parse(param || "") do
      {port, ""} -> port
      _ -> nil
    end
  end

  # The project and env on `port`, or nil (a chat's preview, or nobody's).
  defp env(nil), do: nil

  defp env(port) do
    Enum.find_value(Burrow.Projects.all(), fn project ->
      if project.preview_ports do
        {_previews, ports} = Burrow.Cell.ports(project)
        Enum.find_value(ports, fn {name, p} -> if p == port, do: {project, name} end)
      end
    end)
  end

  # A prod app is everyone's, an internal app's live its project's people's,
  # the rest any pass holder's.
  defp open?({_project, "prod"}, _pass), do: true

  defp open?({project, "live"}, {:ok, user_id}) do
    case Burrow.Repo.get(Burrow.Accounts.User, user_id) do
      nil -> false
      user -> Burrow.Projects.visible?(Burrow.Accounts.Scope.for_user(user), project.id)
    end
  end

  defp open?({_project, "live"}, _pass), do: false
  defp open?(_env, pass), do: match?({:ok, _}, pass)

  # The port addresses' domain, example.com for https://peon-{port}.example.com,
  # when Burrow's own address is in it too (else browsers drop the cookie).
  defp domain do
    with %URI{scheme: "https", host: host} <- URI.parse(Burrow.Ports.url(0)),
         [_ | labels] when labels != [] <- String.split(host, "."),
         domain = Enum.join(labels, "."),
         me = BurrowWeb.Endpoint.host(),
         true <- me == domain or String.ends_with?(me, "." <> domain) do
      domain
    else
      _ -> nil
    end
  end
end
