defmodule PeonWeb.InlineController do
  @moduledoc """
  Burrow's way into the inline chat (`Peon.Inline`), with the token Burrow
  and this Peon share (`PEON_API_TOKEN`). Every action answers with the
  current state; later changes are pushed to Burrow.
  """

  use PeonWeb, :controller

  alias Peon.Inline

  plug :require_token

  def show(conn, _params), do: json(conn, Inline.state())

  def send_message(conn, %{"text" => text, "user" => user} = params) do
    opts = [model: params["model"], effort: params["effort"]]

    case Inline.send_message(text, user, opts) do
      {:ok, _chat_id} -> json(conn, Inline.state())
      {:error, reason} -> error(conn, reason)
    end
  end

  def merge(conn, %{"user" => user}) do
    case Inline.merge(user) do
      {:ok, _landed} -> json(conn, Inline.state())
      {:error, reason} -> error(conn, reason)
    end
  end

  def discard(conn, _params) do
    :ok = Inline.discard()
    json(conn, Inline.state())
  end

  def add_envs(conn, %{"user" => user}) do
    :ok = Inline.add_envs(user)
    json(conn, Inline.state())
  end

  defp error(conn, reason),
    do: conn |> put_status(409) |> json(%{"error" => describe(reason)})

  defp describe(:empty), do: "Write what Peon should do."
  defp describe(:busy), do: "Peon is still working on the last message."
  defp describe(:nothing_to_merge), do: "There is no passed changeset to merge."
  defp describe({:conflict, paths}), do: "Main changed #{Enum.join(paths, ", ")} meanwhile."
  defp describe({:rejected, why}), do: why
  defp describe(reason), do: inspect(reason)

  defp require_token(conn, _opts) do
    token = Application.get_env(:peon, :api_token)

    with "Bearer " <> given <- conn |> get_req_header("authorization") |> List.first(""),
         true <- is_binary(token) and Plug.Crypto.secure_compare(given, token) do
      conn
    else
      _ -> conn |> put_status(401) |> json(%{"error" => "unauthorized"}) |> halt()
    end
  end
end
