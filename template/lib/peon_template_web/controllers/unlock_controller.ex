defmodule PeonTemplateWeb.UnlockController do
  @moduledoc "The shared password page (`PeonTemplate.SiteAccess` mode `:shared_password`)."

  use PeonTemplateWeb, :controller

  alias PeonTemplateWeb.SiteAccess

  def new(conn, _params), do: render_form(conn, nil)

  def create(conn, %{"password" => password}) do
    if SiteAccess.valid_password?(password) do
      return_to = get_session(conn, :site_return_to) || ~p"/"

      conn
      |> SiteAccess.unlock()
      |> delete_session(:site_return_to)
      |> redirect(to: return_to)
    else
      # Slows down guessing.
      Process.sleep(Application.get_env(:peon_template, :unlock_delay, 1_000))

      conn
      |> put_status(:unauthorized)
      |> render_form("That's not the password.")
    end
  end

  def create(conn, _params), do: render_form(conn, nil)

  defp render_form(conn, error),
    do: render(conn, :new, error: error, set?: SiteAccess.password() != nil)
end
