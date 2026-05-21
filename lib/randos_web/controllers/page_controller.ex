defmodule RandosWeb.PageController do
  use RandosWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
