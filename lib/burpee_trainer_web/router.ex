defmodule BurpeeTrainerWeb.Router do
  use BurpeeTrainerWeb, :router

  import BurpeeTrainerWeb.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BurpeeTrainerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  pipeline :redirect_if_authed do
    plug :redirect_if_user_is_authenticated
  end

  scope "/", BurpeeTrainerWeb do
    pipe_through [:browser, :redirect_if_authed]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", BurpeeTrainerWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
  end

  scope "/", BurpeeTrainerWeb do
    pipe_through [:browser, :require_auth]

    get "/", PageController, :home

    live_session :authed,
      on_mount: [{BurpeeTrainerWeb.Auth, :require_authenticated_user}] do
      live "/plans", PlansLive.Index, :index
      live "/plans/new", PlansLive.Edit, :new
      live "/plans/:id/edit", PlansLive.Edit, :edit

      live "/session/:plan_id", SessionLive

      live "/log", LogLive
      live "/history", HistoryLive
      live "/goals", GoalsLive
    end
  end

  if Application.compile_env(:burpee_trainer, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BurpeeTrainerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
