defmodule Peon.Burrow do
  @moduledoc """
  Burrow's API for this Peon (`:burrow_api`, with the `:api_token` both
  share): the projects a user can open, for the workspace's project rail.
  """

  @doc "`[%{id, name, slug, status, url, current}]`, or `[]` without Burrow."
  def projects(email) do
    with api when is_binary(api) <- Application.get_env(:peon, :burrow_api),
         {:ok, %{status: 200, body: %{"projects" => projects}}} <-
           Req.get(
             api <> "/projects",
             # Tests stand in for Burrow with `plug: {Req.Test, Peon.Burrow}`.
             [
               params: [email: email],
               auth: {:bearer, Application.get_env(:peon, :api_token)},
               retry: false,
               receive_timeout: 5_000
             ] ++ Application.get_env(:peon, :burrow_req, [])
           ) do
      for p <- projects do
        %{
          id: p["id"],
          name: p["name"],
          slug: p["slug"],
          status: p["status"],
          url: p["url"],
          current: p["current"] == true
        }
      end
    else
      _ -> []
    end
  end
end
