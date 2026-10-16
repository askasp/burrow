defmodule PeonTemplateWeb.Router do
  use PeonTemplateWeb, :router

  import PeonTemplateWeb.UserAuth
  import PeonTemplateWeb.SiteAccess, only: [require_site_password: 2, require_app_access: 2]

  @frame_ancestors Application.compile_env!(:peon_template, :frame_ancestors)

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PeonTemplateWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "frame-ancestors #{@frame_ancestors}"
    }

    plug :fetch_current_scope_for_user
    plug :require_site_password
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The app's own pages. Who may see them is PeonTemplate.SiteAccess.mode/0.
  scope "/", PeonTemplateWeb do
    pipe_through [:browser, :require_app_access]

    get "/", PageController, :home

    live_session :app, on_mount: [{PeonTemplateWeb.SiteAccess, :app}] do
    end
  end

  scope "/", PeonTemplateWeb do
    pipe_through :browser

    get "/unlock", UnlockController, :new
    post "/unlock", UnlockController, :create
  end

  scope "/", PeonTemplateWeb do
    get "/health", HealthController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", PeonTemplateWeb do
  #   pipe_through :api
  # end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:peon_template, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PeonTemplateWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PeonTemplateWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PeonTemplateWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PeonTemplateWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
