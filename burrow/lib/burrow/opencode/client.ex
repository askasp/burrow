defmodule Burrow.OpenCode.Client do
  @moduledoc "The parts of the opencode server API (v2) that Burrow uses."

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

  @doc "Sends a user message; `skills` are skill ids loaded with it."
  def prompt(conn, session_id, text, skills \\ []) do
    body = %{text: text, skills: Enum.map(skills, &%{id: &1})}

    case Req.post(req(conn), url: "/api/session/#{session_id}/prompt", json: body) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      other -> {:error, other}
    end
  end

  @doc """
  Sets the model (provider/model) and its variant, the thinking level (nil for
  the model's default), for the session's next turns.
  """
  def set_model(conn, session_id, model, variant) do
    [provider, id] = String.split(model, "/", parts: 2)
    ref = %{providerID: provider, id: id}
    ref = if variant, do: Map.put(ref, :variant, variant), else: ref

    case Req.post(req(conn), url: "/api/session/#{session_id}/model", json: %{model: ref}) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      other -> {:error, other}
    end
  end

  @doc "Runs a command (e.g. `review`) with its arguments as a user message."
  def command(conn, session_id, name, arguments) do
    case Req.post(req(conn),
           url: "/api/session/#{session_id}/command",
           json: %{name: name, text: arguments}
         ) do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      other -> {:error, other}
    end
  end

  @doc "The commands opencode found: its own and the workspace's `.opencode/commands`."
  def commands(conn) do
    case Req.get(req(conn), url: "/api/command") do
      {:ok, %{status: 200, body: %{"data" => commands}}} ->
        {:ok, for(c <- commands, do: %{name: c["name"], description: c["description"]})}

      other ->
        {:error, other}
    end
  end

  @doc "The skills opencode found: its own and the workspace's `.opencode/skills` and the like."
  def skills(conn) do
    case Req.get(req(conn), url: "/api/skill") do
      {:ok, %{status: 200, body: %{"data" => skills}}} ->
        {:ok, for(s <- skills, do: %{name: s["id"], description: s["description"]})}

      other ->
        {:error, other}
    end
  end

  @doc "The agent's models (provider/model), in opencode's order; [] if it can't say."
  def model_ids(conn) do
    case Req.get(req(conn), url: "/api/model") do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        for m <- models, do: "#{m["providerID"]}/#{m["id"]}"

      _ ->
        []
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

  def delete_session(conn, session_id) do
    Req.delete(req(conn), url: "/api/session/#{session_id}")
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
