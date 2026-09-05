defmodule Philomena.CloudflareAccess do
  @moduledoc """
  Cloudflare Access one-click login support.

  Verifies the Access JWT forwarded by the Cloudflare edge and maps the
  authenticated email to eligible local accounts. The feature is disabled
  unless both the team domain and application AUD tag are configured.
  """

  alias Philomena.CloudflareAccess.JwksCache

  @type email_pattern :: {:email, String.t()} | {:domain, String.t()}

  @doc """
  Returns the Cloudflare Access configuration, or `nil` when the feature
  is not configured.
  """
  @spec config() ::
          %{team_domain: String.t(), aud: String.t(), issuer: String.t(), certs_url: String.t()}
          | nil
  def config do
    team_domain = Application.get_env(:philomena, :cf_access_team_domain)
    aud = Application.get_env(:philomena, :cf_access_aud)

    if present?(team_domain) and present?(aud) do
      %{
        team_domain: team_domain,
        aud: aud,
        issuer: "https://#{team_domain}",
        certs_url: "https://#{team_domain}/cdn-cgi/access/certs"
      }
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(config())

  @doc """
  Extracts the Access JWT from the request, preferring the header injected
  by the Cloudflare edge over the `CF_Authorization` cookie.
  """
  @spec token_from_conn(Plug.Conn.t()) :: String.t() | nil
  def token_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "cf-access-jwt-assertion") do
      [token | _] when token != "" ->
        token

      _ ->
        conn = Plug.Conn.fetch_cookies(conn)

        case conn.cookies["CF_Authorization"] do
          token when is_binary(token) and token != "" -> token
          _ -> nil
        end
    end
  end

  @doc """
  Fully verifies an Access JWT: RS256 signature against the team JWKS,
  issuer, audience and validity window. Returns the claims on success.
  Never raises.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_token(token) when is_binary(token) do
    case config() do
      nil ->
        {:error, :not_configured}

      config ->
        with {:ok, kid} <- peek_kid(token),
             {:ok, jwk} <- JwksCache.get_key(config.certs_url, kid),
             {:ok, claims} <- verify_signature(jwk, token) do
          validate_claims(claims, config)
        end
    end
  end

  defp peek_kid(token) do
    case JSON.decode!(JOSE.JWS.peek_protected(token)) do
      %{"alg" => "RS256", "kid" => kid} when is_binary(kid) -> {:ok, kid}
      _ -> {:error, :invalid_header}
    end
  rescue
    _ -> {:error, :malformed_token}
  end

  defp verify_signature(jwk, token) do
    case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :malformed_token}
  end

  defp validate_claims(claims, config) do
    now = System.os_time(:second)

    cond do
      claims["iss"] != config.issuer -> {:error, :bad_issuer}
      config.aud not in List.wrap(claims["aud"]) -> {:error, :bad_audience}
      not (is_integer(claims["exp"]) and claims["exp"] > now) -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] > now -> {:error, :not_yet_valid}
      true -> {:ok, claims}
    end
  end

  @doc """
  Returns the email patterns eligible for one-click login for the given
  Access email: always the email itself, plus any patterns configured for
  it in the email map. The map has the form `cf-email=pattern,...`, where
  a pattern is either a full email or an `@domain` wildcard; keys may
  repeat and are matched case-insensitively.
  """
  @spec allowed_email_patterns(String.t()) :: [email_pattern()]
  def allowed_email_patterns(cf_email) when is_binary(cf_email) do
    key = String.downcase(cf_email)

    mapped =
      (Application.get_env(:philomena, :cf_access_email_map) || "")
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn pair ->
        with [k, v] <- String.split(pair, "=", parts: 2),
             true <- String.downcase(String.trim(k)) == key,
             v when v != "" <- String.trim(v) do
          [v]
        else
          _ -> []
        end
      end)

    [cf_email | mapped]
    |> Enum.map(&classify_pattern/1)
    |> Enum.uniq_by(fn {type, value} -> {type, String.downcase(value)} end)
  end

  defp classify_pattern("@" <> domain), do: {:domain, domain}
  defp classify_pattern(email), do: {:email, email}

  @doc """
  Picks the account to sign in automatically out of the allowed set, or `nil`
  when auto-login is unconfigured or the configured account is not among them.

  The configured value is matched case-insensitively against both the account
  name and its email.

  ## Examples

      iex> default_account([%User{name: "plexa"}])
      %User{name: "plexa"}

  """
  @spec default_account([struct()]) :: struct() | nil
  def default_account(accounts) when is_list(accounts) do
    case default_user() do
      nil ->
        nil

      name ->
        Enum.find(accounts, fn account ->
          String.downcase(account.name) == name or String.downcase(account.email) == name
        end)
    end
  end

  @spec default_user() :: String.t() | nil
  defp default_user do
    case Application.get_env(:philomena, :cf_access_default_user) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          name -> String.downcase(name)
        end

      _ ->
        nil
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
