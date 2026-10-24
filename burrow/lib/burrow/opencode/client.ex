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

  @doc """
  Sends a user message; `skills` are skill ids loaded with it, `files`
  attachments (`%{uri, name}`, e.g. an image as a data: URI).
  """
  def prompt(conn, session_id, text, skills \\ [], files \\ []) do
    body = %{text: text, skills: Enum.map(skills, &%{id: &1})}
    body = if files == [], do: body, else: Map.put(body, :files, files)

    case Req.post(req(conn), url: "/api/session/#{session_id}/prompt", json: body) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      other -> {:error, other}
    end
  end

  @doc """
  Input that isn't the user's (Burrow's own "keep going"), with a short
  `description`; it starts a turn like a user message.
  """
  def synthetic(conn, session_id, text, description) do
    body = %{text: text, description: description}

    case Req.post(req(conn), url: "/api/session/#{session_id}/synthetic", json: body) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      other -> {:error, other}
    end
  end

  @doc """
  Asks the session's model about the session, with all of it as context,
  without adding to it. Returns `{:ok, text}`.
  """
  def generate(conn, session_id, prompt) do
    case Req.post(req(conn),
           url: "/api/session/#{session_id}/generate",
           json: %{prompt: prompt},
           receive_timeout: :timer.minutes(3)
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"text" => text}}}} -> {:ok, text}
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

  @doc """
  What the session got while it was busy and hasn't taken in yet, oldest
  first: opencode delivers it at the agent's next step.
  """
  def inbox(conn, session_id) do
    case Req.get(req(conn), url: "/api/session/#{session_id}/inbox") do
      {:ok, %{status: 200, body: %{"data" => items}}} -> {:ok, items}
      other -> {:error, other}
    end
  end

  @doc "Takes back an inbox item before the agent gets it; a delivered one stays."
  def cancel_inbox(conn, session_id, inbox_id) do
    case Req.delete(req(conn), url: "/api/session/#{session_id}/inbox/#{inbox_id}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  @doc "The forms the session waits on someone to answer (e.g. which web search to use)."
  def forms(conn, session_id) do
    case Req.get(req(conn), url: "/api/session/#{session_id}/form") do
      {:ok, %{status: 200, body: %{"data" => forms}}} -> {:ok, forms}
      other -> {:error, other}
    end
  end

  def reply_form(conn, session_id, form_id, answer) do
    case Req.post(req(conn),
           url: "/api/session/#{session_id}/form/#{form_id}/reply",
           json: %{answer: answer}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
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
