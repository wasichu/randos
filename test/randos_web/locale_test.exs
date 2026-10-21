defmodule RandosWeb.LocaleTest do
  use RandosWeb.ConnCase

  import Phoenix.LiveViewTest

  alias RandosWeb.Locale

  describe "from_accept_language/1" do
    test "picks the best supported language, ignoring regions" do
      assert Locale.from_accept_language("pt-BR,pt;q=0.9,en;q=0.8") == "pt"
      assert Locale.from_accept_language("zh-Hant-TW") == "zh"
      assert Locale.from_accept_language("nl;q=1.0, de;q=0.7, fr;q=0.9") == "fr"
      assert Locale.from_accept_language("en-US,en;q=0.9") == "en"
    end

    test "nothing supported (or no header) is nil" do
      assert Locale.from_accept_language("nl,sv;q=0.5") == nil
      assert Locale.from_accept_language("*") == nil
      assert Locale.from_accept_language("") == nil
      assert Locale.from_accept_language(nil) == nil
      assert Locale.from_accept_language("de;q=nonsense") == "de"
    end
  end

  test "every interface language is a practice language, with its own name" do
    assert {"en", "English"} = hd(Locale.all())
    assert {"ar", "العربية"} in Locale.all()
    assert length(Locale.all()) == 15
    assert Locale.dir("ar") == "rtl"
    assert Locale.dir("ja") == "ltr"
  end

  describe "the page's language" do
    test "English by default", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(<html lang="en" dir="ltr">)
    end

    test "from Accept-Language", %{conn: conn} do
      html =
        conn |> put_req_header("accept-language", "fr-CA,fr") |> get(~p"/") |> html_response(200)

      assert html =~ ~s(<html lang="fr" dir="ltr">)
    end

    test "an explicit choice wins over Accept-Language; Arabic is right to left", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "fr")
        |> put_req_cookie(Locale.cookie(), "ar")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ ~s(<html lang="ar" dir="rtl">)
    end

    test "an unsupported cookie is ignored", %{conn: conn} do
      html = conn |> put_req_cookie(Locale.cookie(), "xx") |> get(~p"/") |> html_response(200)
      assert html =~ ~s(<html lang="en")
    end
  end

  describe "the switcher" do
    test "lists every language and marks the current one", %{conn: conn} do
      conn = put_req_cookie(conn, Locale.cookie(), "de")
      {:ok, view, _html} = live(conn, ~p"/about")

      assert has_element?(view, "#locale-switcher #locale-switcher-toggle")

      # One POST form of buttons: a prefetching browser can't trigger it.
      assert has_element?(view, "form#locale-options[method='post'][action='/locale']")

      for {code, _name} <- Locale.all() do
        assert has_element?(
                 view,
                 "#locale-option-#{code}[type='submit'][name='locale'][value='#{code}'][lang='#{code}']"
               )
      end

      assert has_element?(view, "#locale-option-de[aria-current='true']")
      refute has_element?(view, "#locale-option-en[aria-current]")
    end

    test "choosing remembers only the code and goes back to the page", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://www.example.com/about")
        |> post(~p"/locale", %{"locale" => "ja"})

      assert redirected_to(conn) == "/about"

      assert %{value: "ja", max_age: max_age, http_only: true} =
               conn.resp_cookies[Locale.cookie()]

      assert max_age > 0
    end

    test "never follows another site's address back, and ignores unknown languages", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://evil.example/about")
        |> post(~p"/locale", %{"locale" => "es"})

      assert redirected_to(conn) == "/"

      conn =
        build_conn()
        |> put_req_header("referer", "http://www.example.com//evil")
        |> post(~p"/locale", %{"locale" => "es"})

      assert redirected_to(conn) == "/"

      conn = build_conn() |> post(~p"/locale", %{"locale" => "xx"})
      assert redirected_to(conn) == "/"
      refute Map.has_key?(conn.resp_cookies, Locale.cookie())
    end

    test "a GET can't switch the language (only the form's POST)", %{conn: conn} do
      conn = get(conn, "/locale/ja")
      assert conn.status == 404
      refute Map.has_key?(conn.resp_cookies, Locale.cookie())
    end
  end
end
