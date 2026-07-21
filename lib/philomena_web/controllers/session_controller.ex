defmodule PhilomenaWeb.SessionController do
  use PhilomenaWeb, :controller

  alias Philomena.CloudflareAccess
  alias Philomena.Users
  alias PhilomenaWeb.UserAuth

  def new(conn, _params) do
    render(conn, "new.html", error_message: nil, cf_accounts: cf_access_accounts(conn))
  end

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params

    user =
      Users.get_user_by_email_and_password(
        email,
        password,
        &url(~p"/unlocks/#{&1}")
      )

    cond do
      not is_nil(user) and is_nil(user.confirmed_at) ->
        render(
          conn,
          "new.html",
          error_message: "You must confirm your account before logging in.",
          cf_accounts: cf_access_accounts(conn)
        )

      not is_nil(user) ->
        conn
        |> put_flash(:info, "Successfully logged in.")
        |> UserAuth.log_in_user(user, user_params)

      true ->
        render(
          conn,
          "new.html",
          error_message:
            "Invalid email or password. If you're seeing this more than usual, your account may be locked.",
          cf_accounts: cf_access_accounts(conn)
        )
    end
  end

  def cf_access_create(conn, %{"user_id" => user_id}) do
    # Re-verifies the Access JWT and re-derives the allowed account set;
    # the user_id is only ever matched against that set.
    case Enum.find(cf_access_accounts(conn), &(Integer.to_string(&1.id) == user_id)) do
      nil ->
        conn
        |> put_flash(:error, "Cloudflare Access login failed.")
        |> redirect(to: ~p"/sessions/new")

      user ->
        conn
        |> put_flash(:info, "Successfully logged in.")
        |> UserAuth.log_in_user_totp_verified(user)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  defp cf_access_accounts(conn) do
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
end
