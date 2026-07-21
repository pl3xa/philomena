defmodule PhilomenaWeb.SessionCfAccessTest do
  use PhilomenaWeb.ConnCase, async: false

  import Philomena.UsersFixtures
  import Philomena.CfAccessHelpers

  alias Philomena.Repo

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

  describe "POST /sessions/cf_access/:user_id" do
    test "logs in the selected account", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access/#{user.id}")

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
        |> post(~p"/sessions/cf_access/#{horse.id}")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == "/"
    end

    test "marks TOTP as satisfied for accounts with 2FA", %{conn: conn, jwk: jwk, user: user} do
      user =
        user
        |> Ecto.Changeset.change(otp_required_for_login: true)
        |> Repo.update!()

      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access/#{user.id}")

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
        |> post(~p"/sessions/cf_access/#{user.id}")

      assert get_session(conn, :user_token)
      refute get_session(conn, :totp_token)
    end

    test "rejects an account outside the allowed set", %{conn: conn, jwk: jwk} do
      outsider = confirmed_user_fixture(%{name: "outsider", email: "outsider@elsewhere.example"})
      token = make_token(jwk, %{"email" => "hunterray555@gmail.com"})

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access/#{outsider.id}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "rejects a request without a token", %{conn: conn, user: user} do
      conn = post(conn, ~p"/sessions/cf_access/#{user.id}")

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
        |> post(~p"/sessions/cf_access/#{user.id}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == "/sessions/new"
    end

    test "redirects when already logged in", %{conn: conn, jwk: jwk, user: user} do
      token = make_token(jwk, %{"email" => user.email})

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/sessions/cf_access/#{user.id}")

      assert redirected_to(conn) == "/"
    end
  end
end
