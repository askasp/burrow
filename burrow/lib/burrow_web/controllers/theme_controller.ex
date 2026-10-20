defmodule BurrowWeb.ThemeController do
  use BurrowWeb, :controller

  alias Burrow.Accounts

  @doc "Sets the user's theme and goes back to the page they were on."
  def update(conn, %{"theme" => theme}) do
    Accounts.put_theme(conn.assigns.current_scope.user, theme)
    redirect(conn, to: back(conn))
  end

  # Only a path on this site.
  defp back(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{path: "/" <> _ = path, query: query} <- URI.parse(referer),
         false <- String.starts_with?(path, "//") do
      if query, do: path <> "?" <> query, else: path
    else
      _ -> ~p"/projects"
    end
  end
end
