defmodule PeonTemplateWeb.PageController do
  use PeonTemplateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
