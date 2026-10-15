defmodule PeonWeb.ManifestController do
  use PeonWeb, :controller

  @doc "The web app manifest, so phones can install this project's Peon."
  def show(conn, _params) do
    name = if project = Peon.Project.get(), do: project.name, else: "Peon"

    manifest = %{
      name: "#{name} · Peon",
      short_name: name,
      description: "Build #{name} by chatting with its Peon.",
      start_url: "/",
      scope: "/",
      display: "standalone",
      background_color: "#EEECE9",
      theme_color: "#FAF9F7",
      icons: [
        %{src: ~p"/images/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any"},
        %{src: ~p"/images/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any"},
        %{
          src: ~p"/images/icon-maskable-512.png",
          sizes: "512x512",
          type: "image/png",
          purpose: "maskable"
        }
      ]
    }

    conn
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(200, Jason.encode!(manifest))
  end
end
