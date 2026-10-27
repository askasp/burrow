defmodule BurrowWeb.AppController do
  @moduledoc """
  The way into an internal app (`Burrow.Projects.Project.internal?/1`): it
  has no login of its own, Burrow logs people in to it as themselves.

  Burrow's frame of the app, and the app itself when nobody is logged in to
  it, asks `/projects/:id/app?to=<a path in the app>`. Whoever sees the
  project goes on to the app's `/burrow/login` with a token good for a
  minute, signed with the project's key (`BURROW_LOGIN_SECRET` in the app,
  `Burrow.Env`): their email, and whether they own the project (the app's
  admin). The app logs them in and goes on to `to`.
  """

  use BurrowWeb, :controller

  alias Burrow.{Cell, Projects}

  @salt "burrow login"

  @doc "The token for `user` in `project`'s app, as `Burrow.Env` gives the app its key."
  def token(project, user, admin?),
    do:
      Plug.Crypto.sign(Projects.secret(project, "app login"), @salt, %{
        "email" => user.email,
        "admin" => admin?
      })

  def enter(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    project = Projects.get!(scope, id)

    with true <- Projects.Project.internal?(project),
         {_previews, %{"live" => port}} <- Cell.ports(project),
         {:ok, path} <- path(params["to"]) do
      token = token(project, scope.user, Projects.owner?(scope, project))
      query = URI.encode_query(token: token, return_to: path)
      redirect(conn, external: Burrow.Ports.url(port) <> "/burrow/login?" <> query)
    else
      :elsewhere -> conn |> put_status(400) |> text("That isn't a page of this app.")
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  # A page of the app: a path, never "//elsewhere"; its start without one.
  defp path(to) when to in [nil, ""], do: {:ok, "/"}

  defp path("/" <> rest = to),
    do: if(String.starts_with?(rest, ["/", "\\"]), do: :elsewhere, else: {:ok, to})

  defp path(_to), do: :elsewhere
end
