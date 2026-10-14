# Bridges an agent's stdio MCP connection to Peon's MCP socket.
#
# opencode starts this inside the agent container. Each line on stdin is a
# JSON-RPC message; it is POSTed to Peon over the mounted Unix socket and the
# response (if any) is written to stdout as one line. Requests run
# concurrently, so a long submit_changeset doesn't block other messages.

token = System.fetch_env!("PEON_MCP_TOKEN")
socket = System.get_env("PEON_MCP_SOCKET", "/peon/mcp.sock")

defmodule Bridge do
  def post(socket, token, body) do
    {:ok, conn} = :gen_tcp.connect({:local, socket}, 0, [:binary, active: false, packet: :raw])

    request =
      "POST /mcp HTTP/1.1\r\nhost: peon\r\ncontent-type: application/json\r\n" <>
        "authorization: Bearer #{token}\r\ncontent-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <> body

    :ok = :gen_tcp.send(conn, request)
    response = read_all(conn, [])
    :gen_tcp.close(conn)
    [head, payload] = String.split(response, "\r\n\r\n", parts: 2)
    if head =~ ~r/transfer-encoding: chunked/i, do: dechunk(payload, []), else: payload
  end

  defp read_all(conn, acc) do
    case :gen_tcp.recv(conn, 0, :infinity) do
      {:ok, data} -> read_all(conn, [acc | data])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp dechunk(data, acc) do
    [size, rest] = String.split(data, "\r\n", parts: 2)

    case String.to_integer(String.trim(size), 16) do
      0 -> IO.iodata_to_binary(acc)
      n -> dechunk(binary_part(rest, n + 2, byte_size(rest) - n - 2), [acc | binary_part(rest, 0, n)])
    end
  end
end

:stdio
|> IO.stream(:line)
|> Stream.map(&String.trim/1)
|> Stream.reject(&(&1 == ""))
|> Enum.each(fn line ->
  spawn(fn ->
    case Bridge.post(socket, token, line) do
      "" -> :ok
      body -> IO.write(String.trim(body) <> "\n")
    end
  end)
end)

# stdin closed: let in-flight requests finish before exiting.
Process.sleep(:infinity)
