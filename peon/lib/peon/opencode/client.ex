defmodule Peon.OpenCode.Client do
  @moduledoc "The parts of the opencode server API (v2) that Peon uses."

  def ready?(conn) do
    match?({:ok, %{status: 200}}, Req.get(req(conn), url: "/api/info", retry: false))
  end

  def create_session(conn, title) do
    case Req.post(req(conn), url: "/api/session", json: %{title: title}) do
      {:ok, %{status: 200, body: %{"data" => %{"id" => id}}}} -> {:ok, id}
      other -> {:error, other}
    end
  end

  def session_exists?(conn, session_id) do
    match?({:ok, %{status: 200}}, Req.get(req(conn), url: "/api/session/#{session_id}"))
  end

  def prompt(conn, session_id, text) do
    case Req.post(req(conn), url: "/api/session/#{session_id}/prompt", json: %{text: text}) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      other -> {:error, other}
    end
  end

  @doc "The session's messages, oldest first."
  def messages(conn, session_id) do
    case Req.get(req(conn), url: "/api/session/#{session_id}/message") do
      {:ok, %{status: 200, body: %{"data" => messages}}} ->
        {:ok, Enum.reverse(messages)}

      {:ok, %{status: 200, body: messages}} when is_list(messages) ->
        {:ok, Enum.reverse(messages)}

      other ->
        {:error, other}
    end
  end

  def interrupt(conn, session_id) do
    Req.post(req(conn), url: "/api/session/#{session_id}/interrupt")
  end

  defp req(%{base_url: base_url, password: password}) do
    Req.new(
      base_url: base_url,
      auth: {:basic, "opencode:" <> password},
      receive_timeout: 30_000,
      retry: false
    )
  end
end
