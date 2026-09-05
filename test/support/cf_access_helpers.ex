defmodule Philomena.CfAccessHelpers do
  @moduledoc """
  Helpers for forging Cloudflare Access JWTs in tests.

  `configure/2` enables the feature via application env and stubs the JWKS
  fetch with the given key, cleaning everything up on exit. Tests using it
  must not be async, since application env is global.
  """

  @team_domain "test-team.cloudflareaccess.com"
  @aud "test-aud-tag-0123456789abcdef"
  @kid "test-key-1"

  def team_domain, do: @team_domain
  def aud, do: @aud
  def kid, do: @kid

  def generate_jwk, do: JOSE.JWK.generate_key({:rsa, 2048})

  def public_jwk_map(jwk, kid \\ @kid) do
    {_meta, map} = JOSE.JWK.to_public_map(jwk)
    Map.put(map, "kid", kid)
  end

  def configure(jwk, opts \\ []) do
    Philomena.CloudflareAccess.JwksCache.reset()

    keys = Keyword.get(opts, :keys, [public_jwk_map(jwk)])

    Application.put_env(:philomena, :cf_access_team_domain, @team_domain)
    Application.put_env(:philomena, :cf_access_aud, @aud)
    Application.put_env(:philomena, :cf_access_email_map, Keyword.get(opts, :email_map, ""))

    # Always set, so a CF_ACCESS_DEFAULT_USER in the environment cannot switch
    # auto-login on for tests that did not ask for it.
    Application.put_env(:philomena, :cf_access_default_user, Keyword.get(opts, :default_user))

    Application.put_env(:philomena, :cf_access_jwks_fetch_fun, fn _url ->
      {:ok, %{"keys" => keys}}
    end)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:philomena, :cf_access_team_domain)
      Application.delete_env(:philomena, :cf_access_aud)
      Application.delete_env(:philomena, :cf_access_email_map)
      Application.delete_env(:philomena, :cf_access_default_user)
      Application.delete_env(:philomena, :cf_access_jwks_fetch_fun)
      Philomena.CloudflareAccess.JwksCache.reset()
    end)

    :ok
  end

  def make_token(jwk, claims_overrides \\ %{}, header_overrides \\ %{}) do
    claims =
      Map.merge(
        %{
          "email" => "user@example.com",
          "iss" => "https://" <> @team_domain,
          "aud" => [@aud],
          "exp" => System.os_time(:second) + 300
        },
        claims_overrides
      )

    header = Map.merge(%{"alg" => "RS256", "kid" => @kid}, header_overrides)

    {_meta, token} =
      jwk
      |> JOSE.JWT.sign(header, claims)
      |> JOSE.JWS.compact()

    token
  end
end
