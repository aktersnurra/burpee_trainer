defmodule BurpeeTrainerWeb.Router do
  use BurpeeTrainerWeb, :router

  import BurpeeTrainerWeb.Auth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BurpeeTrainerWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_scope)
  end

  pipeline :require_auth do
    plug(:require_authenticated_user)
  end

  pipeline :redirect_if_authed do
    plug(:redirect_if_user_is_authenticated)
  end

  pipeline :authenticated_json do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_scope)
    plug(:require_authenticated_user)
  end

  scope "/", BurpeeTrainerWeb do
    pipe_through([:browser, :redirect_if_authed])

    get("/login", SessionController, :new)
    get("/auth/oidc", OidcController, :request)
    get("/auth/oidc/callback", OidcController, :callback)
  end

  scope "/", BurpeeTrainerWeb do
    pipe_through(:browser)

    delete("/logout", SessionController, :delete)
  end

  scope "/api", BurpeeTrainerWeb do
    pipe_through(:authenticated_json)

    post("/session-pose-traces", PoseTraceUploadController, :create)
  end

  scope "/", BurpeeTrainerWeb do
    pipe_through([:browser, :require_auth])

    get("/videos/stream/:filename", VideoController, :stream)

    live_session :authed,
      on_mount: [{BurpeeTrainerWeb.Auth, :require_authenticated_user}] do
      live("/", HomeLive, :home)
      live("/progress", HomeLive, :history)
      live("/history", HomeLive, :history_moved)
      live("/coach", HomeLive, :coach_moved)
      live("/session/:session_id", SessionLive, :show)
      live("/videos/:video_id/session/:session_id", VideoLive.Show, :session)
    end
  end

  if Application.compile_env(:burpee_trainer, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: BurpeeTrainerWeb.Telemetry)
    end

    scope "/", BurpeeTrainerWeb do
      pipe_through([:browser, :require_auth])

      live_session :dev_authed,
        on_mount: [{BurpeeTrainerWeb.Auth, :require_authenticated_user}] do
        live("/tracking-test", TrackingTestLive)
      end
    end
  end
end
