defmodule PeonWeb.Router do
  use PeonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PeonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :signed_in do
    plug PeonWeb.Auth
  end

  scope "/", PeonWeb do
    pipe_through :browser

    get "/sso", SSOController, :show
    get "/manifest.webmanifest", ManifestController, :show
  end

  scope "/", PeonWeb do
    pipe_through [:browser, :signed_in]

    live_session :signed_in, on_mount: PeonWeb.Auth do
      live "/", ProjectLive, :index
      live "/c/:id", ProjectLive, :conversation
    end
  end

  # Burrow, with the token it shares with this Peon.
  scope "/api/burrow", PeonWeb do
    pipe_through :api

    post "/add-envs", BurrowController, :add_envs
    post "/rail", BurrowController, :rail
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:peon, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PeonWeb.Telemetry
    end
  end
end
