defmodule RandosWeb.LocaleController do
  @moduledoc """
  The language switcher's target: remembers an explicit choice of interface
  language (`RandosWeb.Locale.remember/2`) and goes back to the page it came
  from. Only a path on this site is ever followed, never another host.
  """
  use RandosWeb, :controller

  alias RandosWeb.Locale

  def update(conn, %{"locale" => locale}) do
    conn =
      if Locale.supported?(locale),
        do: Locale.remember(conn, locale),
        else: conn

    redirect(conn, to: back(conn))
  end

  # The referring page's path, if it was this site's; else home.
  defp back(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host, path: "/" <> _ = path} <- URI.parse(referer),
         true <- host == conn.host,
         false <- String.starts_with?(path, "//") do
      path
    else
      _other -> ~p"/"
    end
  end
end
