defmodule BurrowWeb.ManifestController do
  use BurrowWeb, :controller

  @doc "The web app manifest, so phones can install Burrow from the browser."
  def show(conn, _params) do
    manifest = %{
      name: "Peon",
      short_name: "Peon",
      description: "Your projects, each built by its own Peon.",
      start_url: "/projects",
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
