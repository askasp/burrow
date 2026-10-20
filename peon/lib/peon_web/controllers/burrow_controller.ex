defmodule PeonWeb.BurrowController do
  @moduledoc """
  Burrow's way in, with the token Burrow and this Peon share
  (`PEON_API_TOKEN`): turning a live-only project into one with staging and
  prod, and saying that a project in the rail changed (`Peon.Burrow`).
  """

  use PeonWeb, :controller

  plug :require_token

  def add_envs(conn, %{"user" => user}) do
    :ok = Peon.Ship.add_envs(user)
    send_resp(conn, 204, "")
  end

  def rail(conn, _params) do
    Peon.Burrow.rail_changed()
    send_resp(conn, 204, "")
  end

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
