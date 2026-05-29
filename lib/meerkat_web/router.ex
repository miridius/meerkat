defmodule MeerkatWeb.Router do
  use MeerkatWeb, :router

  pipeline :browser do
    plug MeerkatWeb.Loopback
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MeerkatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug MeerkatWeb.Loopback
    plug :accepts, ["svg", "txt", "html"]
  end

  scope "/", MeerkatWeb do
    pipe_through :browser

    live "/", ReviewLive
  end

  scope "/api", MeerkatWeb do
    pipe_through :api

    get "/plantuml/svg", PlantUMLController, :svg
    get "/file", FileContentController, :show
  end
end
