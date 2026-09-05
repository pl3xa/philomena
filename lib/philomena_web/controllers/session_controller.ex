defmodule PhilomenaWeb.SessionController do
  use PhilomenaWeb, :controller

  alias Philomena.Users
  alias PhilomenaWeb.UserAuth

  def new(conn, _params) do
    render(conn, "new.html", error_message: nil)
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
        render(conn, "new.html",
          error_message: "You must confirm your account before logging in."
        )

      not is_nil(user) ->
        conn
        |> put_flash(:info, "Successfully logged in.")
        |> UserAuth.log_in_user(user, user_params)

      true ->
        render(conn, "new.html",
          error_message:
            "Invalid email or password. If you're seeing this more than usual, your account may be locked."
        )
    end
  end

  @doc """
  Signs in as, or switches to, an account associated with the Cloudflare
  Access identity. Also handles the "Logged out" entry of the header
  account switcher.
  """
  def cf_access_create(conn, %{"user_id" => user_id} = params) when is_binary(user_id) do
    return_to = safe_return_to(params)
    current_user = conn.assigns.current_user

    cond do
      user_id == "logout" ->
        conn
        |> put_flash(:info, "Logged out successfully.")
        |> UserAuth.log_out_user(return_to)

      not is_nil(current_user) and Integer.to_string(current_user.id) == user_id ->
        redirect(conn, to: return_to)

      true ->
        # CloudflareAccessPlug re-verifies the Access JWT and re-derives the
        # allowed account set on every request; the user_id is only ever
        # matched against that set.
        case Enum.find(conn.assigns.cf_access_accounts, &(Integer.to_string(&1.id) == user_id)) do
          nil ->
            conn
            |> put_flash(:error, "Cloudflare Access login failed.")
            |> redirect(to: ~p"/sessions/new")

          user ->
            conn
            |> put_session(:user_return_to, return_to)
            |> put_flash(:info, "Successfully logged in.")
            |> log_in_cf_access_user(user, params)
        end
    end
  end

  def cf_access_create(conn, _params) do
    conn
    |> put_flash(:error, "Cloudflare Access login failed.")
    |> redirect(to: ~p"/sessions/new")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  defp log_in_cf_access_user(%{assigns: %{current_user: nil}} = conn, user, params),
    do: UserAuth.log_in_user_totp_verified(conn, user, params)

  defp log_in_cf_access_user(conn, user, _params),
    do: UserAuth.switch_user(conn, user)

  # Only same-origin absolute paths are accepted; anything else, including a
  # protocol-relative "//evil.example", falls back to the site root.
  defp safe_return_to(%{"return_to" => "/" <> rest = path}) when byte_size(path) < 512 do
    if String.starts_with?(rest, "/") or String.contains?(path, "\\") do
      "/"
    else
      path
    end
  end

  defp safe_return_to(_params), do: "/"
end
