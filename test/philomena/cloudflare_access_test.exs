defmodule Philomena.CloudflareAccessTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Philomena.CfAccessHelpers

  alias Philomena.CloudflareAccess

  setup_all do
    %{jwk: generate_jwk()}
  end

  describe "verify_token/1" do
    test "accepts a valid token", %{jwk: jwk} do
      configure(jwk)

      assert {:ok, %{"email" => "user@example.com"}} =
               CloudflareAccess.verify_token(make_token(jwk))
    end

    test "accepts a string aud claim", %{jwk: jwk} do
      configure(jwk)
      assert {:ok, _} = CloudflareAccess.verify_token(make_token(jwk, %{"aud" => aud()}))
    end

    test "returns not_configured when disabled", %{jwk: jwk} do
      Application.delete_env(:philomena, :cf_access_team_domain)
      Application.delete_env(:philomena, :cf_access_aud)

      assert {:error, :not_configured} = CloudflareAccess.verify_token(make_token(jwk))
    end

    test "rejects an expired token", %{jwk: jwk} do
      configure(jwk)
      token = make_token(jwk, %{"exp" => System.os_time(:second) - 10})
      assert {:error, :expired} = CloudflareAccess.verify_token(token)
    end

    test "rejects a not-yet-valid token", %{jwk: jwk} do
      configure(jwk)
      token = make_token(jwk, %{"nbf" => System.os_time(:second) + 300})
      assert {:error, :not_yet_valid} = CloudflareAccess.verify_token(token)
    end

    test "rejects a wrong audience", %{jwk: jwk} do
      configure(jwk)

      assert {:error, :bad_audience} =
               CloudflareAccess.verify_token(make_token(jwk, %{"aud" => "other"}))

      assert {:error, :bad_audience} =
               CloudflareAccess.verify_token(make_token(jwk, %{"aud" => ["other1", "other2"]}))
    end

    test "rejects a wrong issuer", %{jwk: jwk} do
      configure(jwk)

      assert {:error, :bad_issuer} =
               CloudflareAccess.verify_token(make_token(jwk, %{"iss" => "https://evil.example"}))
    end

    test "rejects a token signed by an untrusted key", %{jwk: jwk} do
      configure(jwk)
      forged = make_token(generate_jwk())
      assert {:error, :bad_signature} = CloudflareAccess.verify_token(forged)
    end

    test "rejects a token with an unknown kid", %{jwk: jwk} do
      configure(jwk)
      token = make_token(jwk, %{}, %{"kid" => "no-such-kid"})
      assert {:error, :unknown_kid} = CloudflareAccess.verify_token(token)
    end

    test "rejects unsigned alg=none tokens", %{jwk: jwk} do
      configure(jwk)

      header = Base.url_encode64(JSON.encode!(%{"alg" => "none", "kid" => kid()}), padding: false)

      claims =
        Base.url_encode64(JSON.encode!(%{"email" => "user@example.com"}), padding: false)

      assert {:error, :invalid_header} = CloudflareAccess.verify_token("#{header}.#{claims}.")
    end

    test "rejects garbage tokens", %{jwk: jwk} do
      configure(jwk)
      assert {:error, :malformed_token} = CloudflareAccess.verify_token("not a jwt")
    end

    test "returns an error when the JWKS fetch fails", %{jwk: jwk} do
      configure(jwk)
      Application.put_env(:philomena, :cf_access_jwks_fetch_fun, fn _url -> {:error, :down} end)
      Philomena.CloudflareAccess.JwksCache.reset()

      assert {:error, :fetch_failed} = CloudflareAccess.verify_token(make_token(jwk))
    end

    test "refetches on unknown kid for key rotation, limited by a cooldown", %{jwk: jwk} do
      jwk_b = generate_jwk()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      configure(jwk)
      assert {:ok, _} = CloudflareAccess.verify_token(make_token(jwk))

      rotated_keys = [public_jwk_map(jwk), public_jwk_map(jwk_b, "test-key-2")]

      Application.put_env(:philomena, :cf_access_jwks_fetch_fun, fn _url ->
        Agent.update(counter, &(&1 + 1))
        {:ok, %{"keys" => rotated_keys}}
      end)

      token_b = make_token(jwk_b, %{}, %{"kid" => "test-key-2"})
      assert {:ok, _} = CloudflareAccess.verify_token(token_b)
      assert Agent.get(counter, & &1) == 1

      token_c = make_token(generate_jwk(), %{}, %{"kid" => "test-key-3"})
      assert {:error, :unknown_kid} = CloudflareAccess.verify_token(token_c)
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "allowed_email_patterns/1" do
    setup do
      on_exit(fn -> Application.delete_env(:philomena, :cf_access_email_map) end)
    end

    test "always includes the email itself" do
      Application.put_env(:philomena, :cf_access_email_map, "")
      assert [{:email, "a@b.com"}] = CloudflareAccess.allowed_email_patterns("a@b.com")
    end

    test "adds configured patterns for matching keys, case-insensitively" do
      Application.put_env(
        :philomena,
        :cf_access_email_map,
        "Hunter@Gmail.com=@plexa.dev, hunter@gmail.com = horse@plexa.dev ,other@x.com=@nope.dev"
      )

      assert [
               {:email, "hunter@gmail.com"},
               {:domain, "plexa.dev"},
               {:email, "horse@plexa.dev"}
             ] = CloudflareAccess.allowed_email_patterns("hunter@gmail.com")
    end

    test "skips malformed entries and dedupes case-insensitively" do
      Application.put_env(
        :philomena,
        :cf_access_email_map,
        "garbage,a@b.com=@D.com,a@b.com=@d.com,a@b.com=A@B.com,a@b.com="
      )

      assert [{:email, "a@b.com"}, {:domain, "D.com"}] =
               CloudflareAccess.allowed_email_patterns("a@b.com")
    end
  end

  describe "token_from_conn/1" do
    test "prefers the header over the cookie" do
      conn =
        conn(:get, "/")
        |> Plug.Conn.put_req_header("cf-access-jwt-assertion", "header-token")
        |> put_req_cookie("CF_Authorization", "cookie-token")

      assert CloudflareAccess.token_from_conn(conn) == "header-token"
    end

    test "falls back to the CF_Authorization cookie" do
      conn =
        conn(:get, "/")
        |> put_req_cookie("CF_Authorization", "cookie-token")

      assert CloudflareAccess.token_from_conn(conn) == "cookie-token"
    end

    test "returns nil when neither is present" do
      assert CloudflareAccess.token_from_conn(conn(:get, "/")) == nil
    end
  end
end
