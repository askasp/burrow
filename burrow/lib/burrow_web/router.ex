defmodule BurrowWeb.Router do
  use BurrowWeb, :router

  import BurrowWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BurrowWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BurrowWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/manifest.webmanifest", ManifestController, :show
  end

  # Each project's Peon, with the token it shares with Burrow.
  scope "/api/peon", BurrowWeb do
    pipe_through :api

    get "/:id/projects", PeonController, :projects
    post "/:id/projects", PeonController, :create
    post "/:id/prefs", PeonController, :prefs
    post "/:id/share", PeonController, :share
    post "/:id/hand-over", PeonController, :hand_over
    post "/:id/add-envs", PeonController, :add_envs
    post "/:id/status", PeonController, :status
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:burrow, :dev_routes) do
    pipeline :local_only do
      # The mailbox holds everyone's login links: only for this computer,
      # never through a tunnel.
      plug :only_this_computer
    end

    scope "/dev" do
      pipe_through [:local_only, :browser]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", BurrowWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/projects/:id/open", ProjectController, :open

    live_session :require_authenticated_user,
      on_mount: [{BurrowWeb.UserAuth, :require_authenticated}] do
      live "/projects", ProjectLive.Index, :index
      live "/teams", TeamLive.Index, :index
      live "/ai", AILive, :index
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
    post "/users/theme", ThemeController, :update
  end

  scope "/", BurrowWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{BurrowWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  if Application.compile_env(:burrow, :dev_routes) do
    defp only_this_computer(conn, _opts) do
      if conn.host in ["localhost", "127.0.0.1"] and
           Plug.Conn.get_req_header(conn, "cf-connecting-ip") == [] do
        conn
      else
        conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
      end
    end
  end
end
