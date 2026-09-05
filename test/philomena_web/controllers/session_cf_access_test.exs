defmodule PhilomenaWeb.SessionCfAccessTest do
  use PhilomenaWeb.ConnCase, async: false

  import Philomena.UsersFixtures
  import Philomena.CfAccessHelpers

  alias Philomena.Repo
  alias Philomena.Users

  @remember_me_max_age 60 * 60 * 24 * 365

  setup do
    jwk = generate_jwk()
    configure(jwk, email_map: "hunterray555@gmail.com=@plexa.dev")

    user = confirmed_user_fixture(%{name: "Hunter", email: "hunterray555@gmail.com"})

    %{jwk: jwk, user: user}
  end

  describe "GET /sessions/new" do
    test "lists one-click accounts for the verified email", %{conn: conn, jwk: jwk} do
      confirmed_user_fixture(%{name: "horse", email: "horse@plexa.dev"})
      confirmed_user_fixture(%{name: "otherplexa", email: "other@plexa.dev"})
      user_fixture(%{name: "unconfirmedplexa", email: "unconfirmed@plexa.dev"})
      confirmed_user_fixture(%{name: "unrelated", email: "unrelated@elsewhere.example"})

      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      response = html_response(conn, 200)
      assert response =~ "One-click sign-in"
      assert response =~ "Hunter - hunterray555@gmail.com"
      assert response =~ "horse - horse@plexa.dev"
      assert response =~ "otherplexa - other@plexa.dev"
      refute response =~ "unconfirmed@plexa.dev"
      refute response =~ "unrelated@elsewhere.example"
    end

    test "accepts the token from the CF_Authorization cookie", %{conn: conn, jwk: jwk} do
      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_cookie("CF_Authorization", token)
        |> get(~p"/sessions/new")

      assert html_response(conn, 200) =~ "One-click sign-in"
    end

    test "shows no picker without a token", %{conn: conn} do
      conn = get(conn, ~p"/sessions/new")
      refute html_response(conn, 200) =~ "One-click sign-in"
    end

    test "shows no picker with an invalid token", %{conn: conn, jwk: jwk} do
      forged = make_token(generate_jwk(), %{"email" => "hunterray555@gmail.com"})
      _valid_key = jwk

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", forged)
        |> get(~p"/sessions/new")

      refute html_response(conn, 200) =~ "One-click sign-in"
    end

    test "shows no picker for a token without an email claim", %{conn: conn, jwk: jwk} do
      token = make_token(jwk, %{"email" => nil})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      refute html_response(conn, 200) =~ "One-click sign-in"
    end

    test "shows no picker when the feature is unconfigured", %{conn: conn, jwk: jwk} do
      Application.delete_env(:philomena, :cf_access_team_domain)
      Application.delete_env(:philomena, :cf_access_aud)

      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      refute html_response(conn, 200) =~ "One-click sign-in"
    end

    test "re-renders the picker after a failed password login", %{conn: conn, jwk: jwk} do
      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions", %{
          "user" => %{"email" => "hunterray555@gmail.com", "password" => "wrong"}
        })

      response = html_response(conn, 200)
      assert response =~ "Invalid email or password"
      assert response =~ "One-click sign-in"
    end
  end

  describe "header account switcher" do
    test "renders the accounts and the logged out entry when signed out", %{
      conn: conn,
      jwk: jwk,
      user: user
    } do
      horse = confirmed_user_fixture(%{name: "horse", email: "horse@plexa.dev"})
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      response = html_response(conn, 200)
      assert response =~ ~s(id="account-quick-menu")
      assert response =~ ~s(<option value="#{user.id}">Hunter</option>)
      assert response =~ ~s(<option value="#{horse.id}">horse</option>)
      assert response =~ ~s(<option selected value="logout">Logged out</option>)
    end

    test "marks the signed-in account as selected", %{conn: conn, jwk: jwk, user: user} do
      confirmed_user_fixture(%{name: "horse", email: "horse@plexa.dev"})
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      response = html_response(conn, 200)
      assert response =~ ~s(<option selected value="#{user.id}">Hunter</option>)
      assert response =~ ~s(<option value="logout">Logged out</option>)
      assert response =~ ~s(<input name="return_to" type="hidden" value="/registrations/edit">)
    end

    test "includes a signed-in account outside the allowed set", %{conn: conn, jwk: jwk} do
      outsider = confirmed_user_fixture(%{name: "outsider", email: "outsider@elsewhere.example"})
      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> log_in_user(outsider)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      assert html_response(conn, 200) =~
               ~s(<option selected value="#{outsider.id}">outsider</option>)
    end

    test "is absent without a token", %{conn: conn} do
      conn = get(conn, ~p"/sessions/new")
      refute html_response(conn, 200) =~ "account-quick-menu"
    end
  end

  describe "POST /sessions/cf_access" do
    test "logs in the selected account", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == "/"

      conn = get(conn, "/registrations/edit")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ "Logout</a>"
    end

    test "logs in a mapped domain account", %{conn: conn, jwk: jwk} do
      horse = confirmed_user_fixture(%{name: "horse", email: "horse@plexa.dev"})
      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(horse.id)})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == "/"
    end

    test "marks TOTP as satisfied for accounts with 2FA", %{conn: conn, jwk: jwk, user: user} do
      user = enable_totp(user)
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      assert get_session(conn, :user_token)
      assert get_session(conn, :totp_token)

      # /registrations/edit is behind :ensure_totp; without the bypass this
      # would redirect to /sessions/totp/new.
      conn = get(conn, "/registrations/edit")
      assert html_response(conn, 200)
    end

    test "sets no TOTP token for accounts without 2FA", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      assert get_session(conn, :user_token)
      refute get_session(conn, :totp_token)
    end

    test "rejects an account outside the allowed set", %{conn: conn, jwk: jwk} do
      outsider = confirmed_user_fixture(%{name: "outsider", email: "outsider@elsewhere.example"})
      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(outsider.id)})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "rejects a request without a token", %{conn: conn, user: user} do
      conn = post(conn, ~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "rejects a malformed request", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => %{"nested" => "value"}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "rejects a request when the feature is unconfigured", %{conn: conn, jwk: jwk, user: user} do
      Application.delete_env(:philomena, :cf_access_team_domain)
      Application.delete_env(:philomena, :cf_access_aud)

      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "writes a remember me cookie when requested", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => to_string(user.id),
          "remember_me" => "true"
        })

      assert conn.resp_cookies["user_remember_me"].max_age == @remember_me_max_age
    end

    test "writes no remember me cookie by default", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      refute conn.resp_cookies["user_remember_me"]
    end
  end

  describe "POST /sessions/cf_access while signed in" do
    setup %{jwk: jwk} do
      %{
        horse: confirmed_user_fixture(%{name: "horse", email: "horse@plexa.dev"}),
        token: make_token(jwk, %{"email" => "hunterray555@gmail.com"})
      }
    end

    test "switches to another account and revokes the previous session", %{
      conn: conn,
      token: token,
      user: user,
      horse: horse
    } do
      old_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, old_token)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => to_string(horse.id),
          "return_to" => "/images/new"
        })

      assert redirected_to(conn) == "/images/new"
      assert get_session(conn, :user_token)
      assert get_session(conn, :user_token) != old_token
      refute Users.get_user_by_session_token(old_token)

      conn = get(conn, "/registrations/edit")
      assert html_response(conn, 200) =~ horse.email
    end

    test "inherits the remember me cookie", %{
      conn: conn,
      token: token,
      user: user,
      horse: horse
    } do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => to_string(user.id),
          "remember_me" => "true"
        })

      first = conn.resp_cookies["user_remember_me"].value

      conn =
        conn
        |> recycle()
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(horse.id)})

      assert %{max_age: @remember_me_max_age, value: second} =
               conn.resp_cookies["user_remember_me"]

      assert second != first
    end

    test "does not create a remember me cookie for a session-only login", %{
      conn: conn,
      token: token,
      user: user,
      horse: horse
    } do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(user.id)})

      conn =
        conn
        |> recycle()
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(horse.id)})

      assert conn.resp_cookies["user_remember_me"].max_age == 0
    end

    test "clears a stale TOTP cookie when switching to an account without 2FA", %{
      conn: conn,
      token: token,
      user: user,
      horse: horse
    } do
      enable_totp(user)

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => to_string(user.id),
          "remember_me" => "true"
        })

      assert conn.resp_cookies["user_totp_auth"].max_age == @remember_me_max_age

      conn =
        conn
        |> recycle()
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(horse.id)})

      assert conn.resp_cookies["user_totp_auth"].max_age == 0
    end

    test "selecting the current account is a no-op", %{conn: conn, token: token, user: user} do
      session_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, session_token)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => to_string(user.id),
          "return_to" => "/images/new"
        })

      assert redirected_to(conn) == "/images/new"
      assert get_session(conn, :user_token) == session_token
      assert Users.get_user_by_session_token(session_token)
    end

    test "still rejects an account outside the allowed set", %{
      conn: conn,
      token: token,
      user: user
    } do
      outsider = confirmed_user_fixture(%{name: "outsider", email: "outsider@elsewhere.example"})
      session_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, session_token)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(outsider.id)})

      assert redirected_to(conn) == "/sessions/new"
      assert get_session(conn, :user_token) == session_token
    end

    test "logs out via the logout entry and returns to the current page", %{
      conn: conn,
      token: token,
      user: user
    } do
      session_token = Users.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, session_token)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => "logout",
          "return_to" => "/images/new"
        })

      assert redirected_to(conn) == "/images/new"
      refute get_session(conn, :user_token)
      refute Users.get_user_by_session_token(session_token)
      assert conn.resp_cookies["user_remember_me"].max_age == 0
    end

    test "rejects an off-site return_to", %{conn: conn, token: token, user: user} do
      for return_to <- ["//evil.example/", "https://evil.example/", "/\\evil.example"] do
        conn =
          conn
          |> put_req_header("cf-access-jwt-assertion", token)
          |> post(~p"/sessions/cf_access", %{
            "user_id" => to_string(user.id),
            "return_to" => return_to
          })

        assert redirected_to(conn) == "/"
      end
    end
  end

  describe "auto-login of the default account" do
    setup %{jwk: jwk} do
      configure(jwk, email_map: "hunterray555@gmail.com=@plexa.dev", default_user: "plexa")

      %{
        plexa: confirmed_user_fixture(%{name: "plexa", email: "horse@plexa.dev"}),
        token: make_token(jwk, %{"email" => "hunterray555@gmail.com"})
      }
    end

    test "signs in a signed-out visitor and returns to the requested page", %{
      conn: conn,
      token: token,
      plexa: plexa
    } do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      assert redirected_to(conn) == "/registrations/edit"
      assert get_session(conn, :user_token)

      conn = get(conn, "/registrations/edit")
      assert html_response(conn, 200) =~ plexa.email
    end

    test "keeps the query string of the requested page", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/search?q=safe")

      assert redirected_to(conn) == "/search?q=safe"
    end

    test "writes no remember me cookie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      refute conn.resp_cookies["user_remember_me"]
    end

    test "marks TOTP as satisfied for a default account with 2FA", %{
      conn: conn,
      token: token,
      plexa: plexa
    } do
      enable_totp(plexa)

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      assert get_session(conn, :totp_token)

      conn = get(conn, "/registrations/edit")
      assert html_response(conn, 200)
    end

    test "leaves an already signed-in account alone", %{conn: conn, token: token, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      assert html_response(conn, 200) =~ user.email
    end

    test "does not fire on a non-GET request", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions", %{
          "user" => %{"email" => "hunterray555@gmail.com", "password" => "wrong"}
        })

      refute get_session(conn, :user_token)
      assert html_response(conn, 200) =~ "Invalid email or password"
    end

    test "does not fire without a valid token", %{conn: conn} do
      conn = get(conn, ~p"/sessions/new")

      refute get_session(conn, :user_token)
      assert html_response(conn, 200) =~ "Sign in"
    end

    test "does not fire when the default account is outside the allowed set", %{
      conn: conn,
      jwk: jwk,
      token: token
    } do
      configure(jwk, email_map: "hunterray555@gmail.com=@plexa.dev", default_user: "nobody")

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      refute get_session(conn, :user_token)
      assert html_response(conn, 200) =~ "One-click sign-in"
    end

    test "does not fire when no default account is configured", %{
      conn: conn,
      jwk: jwk,
      token: token
    } do
      configure(jwk, email_map: "hunterray555@gmail.com=@plexa.dev")

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      refute get_session(conn, :user_token)
      assert html_response(conn, 200) =~ "One-click sign-in"
    end

    test "stays signed out after the logged out entry is picked", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{
          "user_id" => "logout",
          "return_to" => "/registrations/edit"
        })

      assert conn.resp_cookies["cf_access_opt_out"].max_age == @remember_me_max_age

      conn =
        conn
        |> recycle()
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "stays signed out after the logout link is used", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      assert get_session(conn, :user_token)

      conn = delete(recycle(conn), ~p"/sessions")
      assert conn.resp_cookies["cf_access_opt_out"].max_age == @remember_me_max_age

      conn =
        conn
        |> recycle()
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "resumes after the picker signs an account back in", %{
      conn: conn,
      token: token,
      plexa: plexa
    } do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => "logout"})

      conn =
        conn
        |> recycle()
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access", %{"user_id" => to_string(plexa.id)})

      assert conn.resp_cookies["cf_access_opt_out"].max_age == 0
    end

    test "does not retry after an attempt that left the session signed out", %{
      conn: conn,
      token: token
    } do
      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get("/registrations/edit")

      assert conn.resp_cookies["cf_access_auto_login"]

      # Same browser, but the session cookie did not stick.
      conn =
        conn
        |> recycle()
        |> delete_req_cookie("_philomena_key")
        |> put_req_header("cf-access-jwt-assertion", token)
        |> get(~p"/sessions/new")

      refute get_session(conn, :user_token)
      assert html_response(conn, 200) =~ "One-click sign-in"
    end
  end

  defp enable_totp(user) do
    user
    |> Ecto.Changeset.change(otp_required_for_login: true)
    |> Repo.update!()
  end
end
