defmodule Burrow.OpenCode do
  @moduledoc """
  Each user's AI logins. opencode keeps them in the user's opencode data
  directory; the user's Peons mount that directory, so every agent they run
  uses these logins and the user's subscriptions.

  Logins are managed through opencode's own API (`Burrow.OpenCode.Server`):
  an API key, or OAuth (e.g. "Sign in with ChatGPT").
  """

  alias Burrow.Accounts.User
  alias Burrow.OpenCode.Server
  alias Burrow.Repo

  # The providers offered on the AI page, in this order.
  @providers ~w(openai opencode-go opencode anthropic openrouter github-copilot)

  def data_dir(user_id),
    do: Path.join([Application.fetch_env!(:burrow, :data_dir), "users", "#{user_id}", "opencode"])

  @doc "The model the user's agents use, as provider/model."
  def model(user_id) do
    case Repo.get(User, user_id) do
      %User{ai_model: model} when is_binary(model) and model != "" -> model
      _ -> Application.fetch_env!(:burrow, :opencode_model)
    end
  end

  def set_model(user_id, model) do
    Repo.get!(User, user_id) |> Ecto.Changeset.change(ai_model: model) |> Repo.update()
  end

  @doc "The offered providers: `%{id, name, connected?, key?, oauth: [%{id, label}]}`."
  def providers(user_id) do
    with {:ok, %{"data" => integrations}} <- Server.request(user_id, :get, "/integration") do
      by_id = Map.new(integrations, &{&1["id"], &1})

      providers =
        for id <- @providers, integration = by_id[id] do
          methods = integration["methods"]

          %{
            id: id,
            name: integration["name"],
            connected?: integration["connections"] |> Enum.any?(&(&1["type"] == "credential")),
            key?: Enum.any?(methods, &(&1["type"] == "key")),
            oauth: for(%{"type" => "oauth"} = m <- methods, do: %{id: m["id"], label: m["label"]})
          }
        end

      {:ok, providers}
    end
  end

  def connected?(user_id) do
    case providers(user_id) do
      {:ok, providers} -> Enum.any?(providers, & &1.connected?)
      _ -> false
    end
  end

  def connect_key(user_id, provider, key) do
    with {:ok, _} <-
           Server.request(user_id, :post, "/integration/#{provider}/connect/key", %{key: key}),
         do: :ok
  end

  @doc "Starts an OAuth login. Returns `%{attempt_id, url, instructions, mode}`; mode is auto or code."
  def start_oauth(user_id, provider, method_id) do
    with {:ok, %{"data" => attempt}} <-
           Server.request(user_id, :post, "/integration/#{provider}/connect/oauth", %{
             methodID: method_id
           }) do
      {:ok,
       %{
         provider: provider,
         attempt_id: attempt["attemptID"],
         url: attempt["url"],
         instructions: attempt["instructions"],
         mode: attempt["mode"]
       }}
    end
  end

  @doc "Status of an OAuth login: pending, complete, or another final status."
  def oauth_status(user_id, provider, attempt_id) do
    with {:ok, %{"data" => %{"status" => status}}} <-
           Server.request(user_id, :get, "/integration/#{provider}/connect/oauth/#{attempt_id}"),
         do: {:ok, status}
  end

  def complete_oauth(user_id, provider, attempt_id, code) do
    with {:ok, _} <-
           Server.request(
             user_id,
             :post,
             "/integration/#{provider}/connect/oauth/#{attempt_id}/complete",
             %{
               code: code
             }
           ),
         do: :ok
  end

  @doc """
  Models the user can pick, in opencode's order: `{provider/model id, the
  model's variants}`, its thinking levels (e.g. `["low", "medium", "high"]`).
  """
  def models(user_id) do
    with {:ok, %{"data" => models}} <- Server.request(user_id, :get, "/model") do
      {:ok,
       for(
         m <- models || [],
         do: {"#{m["providerID"]}/#{m["id"]}", Enum.map(m["variants"] || [], & &1["id"])}
       )}
    end
  end

  @doc """
  `model` if it is among `ids` (the models the user's logins give, in
  opencode's order), else opencode's first: a model whose login is gone, or
  the default with no login at all, would fail every turn.
  """
  def usable(model, []), do: model
  def usable(model, ids), do: if(model in ids, do: model, else: hd(ids))

  @doc """
  Local mode only: copies the logins of this computer's own opencode into the
  user's opencode, so a developer can use their subscriptions right away.
  """
  def import_local_logins(user_id) do
    if Application.get_env(:burrow, :local_login_import, false) do
      with {:ok, entries} <- local_credentials() do
        Enum.each(entries, fn entry ->
          Server.request(user_id, :post, "/credential", %{
            integrationID: entry["integrationID"],
            label: entry["label"],
            value: entry["value"],
            activate: true
          })
        end)

        {:ok, Enum.map(entries, & &1["integrationID"])}
      end
    else
      {:error, :disabled}
    end
  end

  defp local_credentials do
    case System.cmd(Application.fetch_env!(:burrow, :opencode_bin), ["api", "credential.list"],
           stderr_to_stdout: false
         ) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, %{"data" => entries}} -> {:ok, entries}
          {:ok, entries} when is_list(entries) -> {:ok, entries}
          _ -> {:error, :unreadable}
        end

      {_, _} ->
        {:error, :opencode_not_logged_in}
    end
  end
end
