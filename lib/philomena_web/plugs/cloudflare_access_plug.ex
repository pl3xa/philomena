defmodule PhilomenaWeb.CloudflareAccessPlug do
  @moduledoc """
  This plug assigns the local accounts eligible for Cloudflare Access
  one-click login, based on the Access JWT forwarded by the edge. The
  assign is an empty list when the feature is unconfigured or the request
  carries no valid token.

  When `CF_ACCESS_DEFAULT_USER` names one of those accounts, a visitor who
  would otherwise browse signed out is signed in as it and redirected back to
  the page they asked for, so the rest of the pipeline runs with the session
  in place. Choosing "Logged out" in the header switcher — or any other
  logout — opts the browser out until it signs in again.

  Must be plugged after `fetch_current_user`.

  ## Example

      plug PhilomenaWeb.CloudflareAccessPlug
  """

  alias Philomena.CloudflareAccess
  alias Philomena.Users
  alias PhilomenaWeb.UserAuth
  alias Plug.Conn

  @doc false
  @spec init(any()) :: any()
  def init(opts), do: opts

  @doc false
  @spec call(Conn.t(), any()) :: Conn.t()
  def call(conn, _opts) do
    accounts = accounts(conn)

    conn
    |> Conn.assign(:cf_access_accounts, accounts)
    |> maybe_auto_login(accounts)
  end

  defp accounts(conn) do
    with true <- CloudflareAccess.enabled?(),
         token when is_binary(token) <- CloudflareAccess.token_from_conn(conn),
         {:ok, %{"email" => email}} when is_binary(email) <- CloudflareAccess.verify_token(token) do
      email
      |> CloudflareAccess.allowed_email_patterns()
      |> Users.list_users_for_email_patterns()
    else
      _ -> []
    end
  end

  # Only navigations are auto-logged-in: a GET can be answered with a redirect
  # to itself without losing anything the request carried.
  defp maybe_auto_login(%{method: "GET", assigns: %{current_user: nil}} = conn, accounts) do
    with true <- UserAuth.cf_access_auto_login_allowed?(conn),
         user when not is_nil(user) <- CloudflareAccess.default_account(accounts) do
      conn
      |> Conn.put_session(:user_return_to, Phoenix.Controller.current_path(conn))
      |> UserAuth.mark_cf_access_auto_login()
      |> UserAuth.log_in_user_totp_verified(user)
      |> Conn.halt()
    else
      _ -> conn
    end
  end

  defp maybe_auto_login(conn, _accounts), do: conn
end
