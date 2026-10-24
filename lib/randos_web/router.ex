defmodule RandosWeb.Router do
  use RandosWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RandosWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug RandosWeb.Locale
  end

  # The language switcher's POST: the session and cookies only. No CSRF
  # token, on purpose: the switcher sits in the LiveView layout, and the
  # worst a forged request can do is change someone's interface language.
  pipeline :locale do
    plug :fetch_session
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RandosWeb do
    pipe_through :browser

    live_session :default, on_mount: RandosWeb.Locale do
      live "/", HomeLive, :home
      # An invitation link (the token is in the fragment: never sent here).
      live "/join", HomeLive, :join
      live "/about", AboutLive, :about
      live "/status", StatusLive, :status
      live "/translations", TranslationsLive, :index
    end
  end

  # The language switcher: a small form (works without JavaScript; a POST,
  # so a browser prefetching links can't switch the language). It only
  # remembers the choice and goes back.
  scope "/", RandosWeb do
    pipe_through :locale

    post "/locale", LocaleController, :update
  end

  # Other scopes may use custom stacks.
  # scope "/api", RandosWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:randos, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RandosWeb.Telemetry

      # The voice lab (Phase 5): dev only, modules in dev/.
      live "/voice-lab", RandosDev.VoiceLabLive, :index
      get "/voice-lab/clips", RandosDev.VoiceLabClips, :index
      get "/voice-lab/clips/:name", RandosDev.VoiceLabClips, :show

      # The translation shootout's review page (Phase 6): dev only, modules in dev/.
      live "/translations", RandosDev.TranslationReviewLive, :index
    end
  end
end
