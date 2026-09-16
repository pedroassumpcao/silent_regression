defmodule SilentRegressionWeb.Router do
  use SilentRegressionWeb, :router

  import SilentRegressionWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SilentRegressionWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug Inertia.Plug
    plug SilentRegressionWeb.Plugs.InertiaSharedProps
  end

  pipeline :authenticated do
    plug :require_authenticated_user
  end

  pipeline :workspace_scope do
    plug SilentRegressionWeb.Plugs.FetchWorkspaceScope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SilentRegressionWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/security", PageController, :security
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    get "/design-partner/apply", DesignPartnerApplicationController, :new
    post "/design-partner/apply", DesignPartnerApplicationController, :create
    get "/design-partner/apply/thanks", DesignPartnerApplicationController, :thanks
    get "/robots.txt", SEOController, :robots
    get "/sitemap.xml", SEOController, :sitemap
  end

  scope "/", SilentRegressionWeb do
    pipe_through [:browser, :authenticated]

    get "/app", AppController, :entry
    get "/users/settings", UserSettingsController, :edit
    put "/users/settings/email", UserSettingsController, :update_email
    put "/users/settings/password", UserSettingsController, :update_password
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/app/:workspace_slug", SilentRegressionWeb do
    pipe_through [:browser, :authenticated, :workspace_scope]

    get "/", AppController, :index
    get "/monitors", AppController, :monitors
    get "/monitors/new", MonitorSetupController, :new
    post "/monitors", MonitorSetupController, :create
    get "/monitors/:monitor_id/setup", MonitorSetupController, :resume
    get "/monitors/:monitor_id/setup/:step", MonitorSetupController, :show
    patch "/monitors/:monitor_id/setup/:step", MonitorSetupController, :update
    post "/monitors/:monitor_id/setup/complete", MonitorSetupController, :complete
    post "/monitors/:monitor_id/setup/leave", MonitorSetupController, :leave
    get "/monitors/:monitor_id/contract", ContractAuthoringController, :show
    put "/monitors/:monitor_id/contract", ContractAuthoringController, :save
    post "/monitors/:monitor_id/contract/fixtures", ContractAuthoringController, :create_fixture

    patch "/monitors/:monitor_id/contract/fixtures/:fixture_id",
          ContractAuthoringController,
          :update_fixture

    delete "/monitors/:monitor_id/contract/fixtures/:fixture_id",
           ContractAuthoringController,
           :delete_fixture

    post "/monitors/:monitor_id/contract/approve", ContractAuthoringController, :approve
    post "/monitors/:monitor_id/contract/revise", ContractAuthoringController, :revise
    get "/monitors/:monitor_id/baseline", BaselineController, :show
    post "/monitors/:monitor_id/baseline/validate-model", BaselineController, :validate_model
    post "/monitors/:monitor_id/baseline/authorize", BaselineController, :authorize
    post "/monitors/:monitor_id/baseline/approve", BaselineController, :approve
    post "/monitors/:monitor_id/baseline/reject", BaselineController, :reject
    get "/monitors/:monitor_id/operations", MonitorOperationsController, :show
    patch "/monitors/:monitor_id/operations/schedule", MonitorOperationsController, :configure
    post "/monitors/:monitor_id/operations/run-now", MonitorOperationsController, :run_now
    post "/monitors/:monitor_id/operations/pause", MonitorOperationsController, :pause
    post "/monitors/:monitor_id/operations/resume", MonitorOperationsController, :resume
    get "/monitors/:monitor_id/results", RunResultController, :index
    get "/monitors/:monitor_id/runs/:run_id", RunResultController, :show
    get "/monitors/:monitor_id/runs/:run_id/diagnostic", RunResultController, :diagnostic
    post "/monitors/:monitor_id/runs/:run_id/reviews", ReviewController, :create

    post "/monitors/:monitor_id/runs/:run_id/reviews/:review_id/contract-revision",
         ReviewController,
         :start_contract_revision

    get "/alerts", ResultAlertController, :index
    post "/alerts/:alert_id/acknowledge", ResultAlertController, :acknowledge
    post "/alerts/:alert_id/resolve", ResultAlertController, :resolve
    get "/credentials", ProviderCredentialController, :index
    post "/credentials", ProviderCredentialController, :create
    post "/credentials/:id/validate", ProviderCredentialController, :validate
    post "/credentials/:id/rotate", ProviderCredentialController, :rotate
    delete "/credentials/:id", ProviderCredentialController, :revoke
  end

  scope "/", SilentRegressionWeb do
    pipe_through :browser

    get "/invitations/:token", WorkspaceInvitationController, :show
    post "/invitations/:token", WorkspaceInvitationController, :accept

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Other scopes may use custom stacks.
  # scope "/api", SilentRegressionWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:silent_regression, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SilentRegressionWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
