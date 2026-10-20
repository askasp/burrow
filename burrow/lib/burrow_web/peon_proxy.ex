defmodule BurrowWeb.PeonProxy do
  @moduledoc """
  Each project's workspace on Burrow's own site: `/w/<port>/...` goes to the
  Peon on that port without the prefix (the Peon knows it as `PEON_PATH`, see
  `Burrow.Ports.peon_url/1`), its LiveView socket included
  (`BurrowWeb.PeonProxy.Socket`). On the same origin as Burrow, an installed
  Burrow app keeps the workspace in its own window instead of a browser
  sheet. Only ports that belong to a project are passed on; the Peon signs
  its users in itself.
  """

  @behaviour Plug

  import Plug.Conn

  # Headers that belong to one connection, not the request
  @hop ~w(connection keep-alive proxy-connection transfer-encoding te trailer upgrade host content-length)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["w", port | _]} = conn, _opts) do
    with {port, ""} <- Integer.parse(port),
         true <- Burrow.Projects.peon_port?(port) do
      conn |> proxy(port) |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp proxy(conn, port) do
    path = String.replace_prefix(conn.request_path, "/w/#{port}", "")

    cond do
      path == "" ->
        conn |> put_resp_header("location", "/w/#{port}/") |> send_resp(308, "")

      websocket?(conn) ->
        state = %{port: port, path: with_query(path, conn), headers: forward_headers(conn)}
        WebSockAdapter.upgrade(conn, BurrowWeb.PeonProxy.Socket, state, timeout: 120_000)

      true ->
        http(conn, port, with_query(path, conn))
    end
  end

  defp http(conn, port, path) do
    {body, conn} = read_all(conn, [])

    Req.request(
      method: conn.method,
      url: "http://127.0.0.1:#{port}#{path}",
      headers: forward_headers(conn),
      body: body,
      # Passed on as they are: compressed bodies, redirects, cookies
      raw: true,
      compressed: false,
      redirect: false,
      retry: false,
      receive_timeout: 60_000
    )
    |> case do
      {:ok, resp} ->
        resp.headers
        |> Enum.reject(fn {name, _} -> name in @hop end)
        |> Enum.reduce(conn, fn {name, values}, conn ->
          conn
          |> delete_resp_header(name)
          |> prepend_resp_headers(Enum.map(values, &{name, &1}))
        end)
        |> send_resp(resp.status, resp.body)

      {:error, _} ->
        send_resp(conn, 502, "This project's Peon isn't running. Open it from Burrow again.")
    end
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_all(conn, [chunk | acc])
    end
  end

  defp websocket?(conn) do
    conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp with_query(path, %{query_string: ""}), do: path
  defp with_query(path, %{query_string: query}), do: path <> "?" <> query

  defp forward_headers(conn) do
    kept =
      for {name, value} <- conn.req_headers,
          name not in @hop,
          not String.starts_with?(name, "sec-websocket-"),
          do: {name, value}

    proto = List.first(get_req_header(conn, "x-forwarded-proto")) || to_string(conn.scheme)

    Enum.reject(kept, fn {name, _} -> name in ~w(x-forwarded-proto x-forwarded-host) end) ++
      [
        {"x-forwarded-proto", proto},
        {"x-forwarded-host", conn.host},
        {"x-forwarded-for", conn.remote_ip |> :inet.ntoa() |> to_string()}
      ]
  end
end
