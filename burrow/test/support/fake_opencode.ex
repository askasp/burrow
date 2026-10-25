defmodule Burrow.FakeOpenCode do
  @moduledoc """
  Stands in for a user's `Burrow.OpenCode.Server` in tests: an opencode in
  memory with the integration, credential and model API, registered under
  the user's id so `Burrow.OpenCode` talks to it over Req.

  Like opencode, a provider uses one login at a time: a new key through
  connect/key is used at once, and when the login in use goes, the newest
  other one takes over.
  """

  use GenServer

  @providers [
    {"openai", "OpenAI", [%{"type" => "oauth", "id" => "chatgpt", "label" => "ChatGPT"}]},
    {"opencode-go", "OpenCode Go", []},
    {"opencode", "OpenCode Console",
     [%{"type" => "oauth", "id" => "device", "label" => "OpenCode Console account"}]},
    {"anthropic", "Anthropic", []},
    {"openrouter", "OpenRouter", []}
  ]

  def child_spec(user_id),
    do: %{id: {__MODULE__, user_id}, start: {__MODULE__, :start_link, [user_id]}}

  def start_link(user_id), do: GenServer.start_link(__MODULE__, nil, name: via(user_id))

  @doc "The user's logins, values and all."
  def credentials(user_id), do: GenServer.call(via(user_id), :credentials)

  @doc "Adds a login as if the user had signed in or connected a key; it is used at once."
  def add(user_id, provider, value), do: GenServer.call(via(user_id), {:add, provider, value})

  @doc "Makes login `id` the one its provider uses."
  def activate(user_id, id), do: GenServer.call(via(user_id), {:activate, id})

  defp via(user_id), do: {:via, Registry, {Burrow.OpenCodeRegistry, user_id}}

  @impl true
  def init(nil), do: {:ok, %{credentials: [], n: 0}}

  @impl true
  def handle_call(:req, _from, state) do
    me = self()
    plug = fn conn -> serve(me, conn) end

    {:reply, {:ok, Req.new(base_url: "http://opencode.test/api", plug: plug, retry: false)},
     state}
  end

  def handle_call(:credentials, _from, state), do: {:reply, state.credentials, state}

  def handle_call({:add, provider, value}, _from, state) do
    {id, state} = add(state, nil, provider, nil, value, true)
    {:reply, id, state}
  end

  def handle_call({:activate, id}, _from, state), do: {:reply, :ok, use_login(state, id)}

  def handle_call({:api, method, path, body}, _from, state) do
    {status, response, state} = api(method, String.split(path, "/", trim: true), body, state)
    {:reply, {status, response}, state}
  end

  defp api("GET", ["api", "integration"], _body, state) do
    integrations =
      for {id, name, oauth} <- @providers do
        %{
          "id" => id,
          "name" => name,
          "methods" => [%{"type" => "key", "id" => "key", "label" => "API key"} | oauth],
          "connections" =>
            for(
              c <- state.credentials,
              c["integrationID"] == id,
              do: %{
                "type" => "credential",
                "id" => c["id"],
                "label" => c["label"],
                "method" => c["value"]["type"]
              }
            )
        }
      end

    {200, %{"data" => integrations}, state}
  end

  defp api("GET", ["api", "model"], _body, state) do
    models =
      for c <- state.credentials,
          c["active"],
          do: %{"providerID" => c["integrationID"], "id" => "test-model", "variants" => []}

    {200, %{"data" => models}, state}
  end

  defp api("GET", ["api", "credential"], _body, state),
    do: {200, %{"data" => state.credentials}, state}

  defp api("POST", ["api", "credential"], body, state) do
    if Enum.any?(state.credentials, &(&1["id"] == body["id"])) do
      {409, %{"_tag" => "ConflictError"}, state}
    else
      {id, state} =
        add(
          state,
          body["id"],
          body["integrationID"],
          body["label"],
          body["value"],
          body["activate"]
        )

      {200, %{"data" => Enum.find(state.credentials, &(&1["id"] == id))}, state}
    end
  end

  defp api("POST", ["api", "credential", id, "activate"], _body, state),
    do: {204, nil, use_login(state, id)}

  defp api("DELETE", ["api", "credential", id], _body, state) do
    gone = Enum.find(state.credentials, &(&1["id"] == id))
    state = %{state | credentials: Enum.reject(state.credentials, &(&1["id"] == id))}

    state =
      with %{"active" => true, "integrationID" => provider} <- gone,
           %{"id" => newest} <-
             state.credentials |> Enum.filter(&(&1["integrationID"] == provider)) |> List.last(),
           do: use_login(state, newest),
           else: (_ -> state)

    {204, nil, state}
  end

  defp api("POST", ["api", "integration", provider, "connect", "key"], body, state) do
    {_id, state} =
      add(state, nil, provider, provider, %{"type" => "key", "key" => body["key"]}, true)

    {204, nil, state}
  end

  defp api(_method, _path, _body, state), do: {404, %{"message" => "not found"}, state}

  defp add(state, id, provider, label, value, active?) do
    n = state.n + 1
    id = id || "cred_#{n}"

    credential = %{
      "id" => id,
      "integrationID" => provider,
      "label" => label || provider,
      "value" => value,
      "active" => false
    }

    state = %{state | n: n, credentials: state.credentials ++ [credential]}
    {id, if(active?, do: use_login(state, id), else: state)}
  end

  defp use_login(state, id) do
    provider = Enum.find_value(state.credentials, &(&1["id"] == id && &1["integrationID"]))

    credentials =
      for c <- state.credentials do
        if c["integrationID"] == provider, do: %{c | "active" => c["id"] == id}, else: c
      end

    %{state | credentials: credentials}
  end

  defp serve(pid, conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)

    case GenServer.call(pid, {:api, conn.method, conn.request_path, body}) do
      {204, nil} -> Plug.Conn.send_resp(conn, 204, "")
      {status, response} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
    end
  end
end
