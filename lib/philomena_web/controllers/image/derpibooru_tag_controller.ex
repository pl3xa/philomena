defmodule PhilomenaWeb.Image.DerpibooruTagController do
  use PhilomenaWeb, :controller

  alias Philomena.Derpibooru.{Client, TagMerge}
  alias Philomena.Images
  alias Philomena.Images.Image

  plug PhilomenaWeb.FilterBannedUsersPlug
  plug PhilomenaWeb.UserAttributionPlug
  plug PhilomenaWeb.CanaryMapPlug, create: :edit_metadata, update: :edit_metadata

  plug :load_and_authorize_resource,
    model: Image,
    id_name: "image_id",
    persisted: true,
    preload: [:user, :locked_tags, :sources, tags: :aliases]

  plug :configured
  plug :throttle

  def create(conn, params) do
    result =
      case params do
        %{"derpibooru_id" => id} -> manual(id)
        %{"mode" => "reverse"} -> reverse(conn)
        _ -> {:error, :invalid_id}
      end

    case result do
      {:ok, candidates} ->
        previews =
          Enum.map(
            candidates,
            &TagMerge.preview(conn.assigns.image, &1, conn.assigns.current_user)
          )

        json(conn, %{candidates: previews})

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  def update(conn, %{"token" => token}) when is_binary(token) and byte_size(token) < 300_000 do
    case TagMerge.merge(conn.assigns.image, conn.assigns.attributes, token) do
      {:ok, result} ->
        json(conn, %{result: result})

      {:error, {:stale, candidate}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "Tags changed since this preview. Review the updated tag changes and try again.",
          candidate: candidate
        })

      {:error, {:invalid_tags, errors}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Cannot merge these tags: " <> Enum.join(errors, "; ")})

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  def update(conn, _), do: failure(conn, :invalid_preview)

  defp manual(id) when is_binary(id) do
    if Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, id) do
      with {:ok, candidate} <- Client.image(String.to_integer(id)), do: {:ok, [candidate]}
    else
      {:error, :invalid_id}
    end
  end

  defp manual(_), do: {:error, :invalid_id}

  defp reverse(conn) do
    case Images.create_temp_share(conn.assigns.image, conn.assigns.attributes) do
      {:ok, url} -> Client.reverse(url)
      _ -> {:error, :share_failed}
    end
  end

  defp configured(conn, _) do
    cond do
      not Client.configured?() -> conn |> failure(:not_configured) |> halt()
      is_nil(TagMerge.system_user()) -> conn |> failure(:system_user_missing) |> halt()
      true -> conn
    end
  end

  defp throttle(conn, _) do
    key = "derpibooru:request:#{conn.assigns.current_user.id}:#{action_name(conn)}"

    case Redix.command(:redix, ["SET", key, "1", "NX", "EX", "5"]) do
      {:ok, "OK"} -> conn
      {:ok, nil} -> conn |> failure(:local_rate_limit) |> halt()
      _ -> conn |> failure(:unavailable) |> halt()
    end
  end

  defp failure(conn, reason) do
    {status, message} =
      case reason do
        {:unavailable_candidates, _count} ->
          {:unprocessable_entity,
           "Derpibooru returned hidden or deleted matches. Use a manual ID to select an available image."}

        :invalid_id ->
          {:bad_request, "Enter a positive numeric Derpibooru image ID."}

        :invalid_preview ->
          {:unprocessable_entity, "This preview expired or is invalid. Check Derpibooru again."}

        :preview_changed ->
          {:conflict, "Local tag rules changed. Check Derpibooru again before merging."}

        :not_found ->
          {:not_found, "That Derpibooru image is unavailable or deleted."}

        :forbidden ->
          {:forbidden, "You can no longer edit this image's tags."}

        :local_rate_limit ->
          {:too_many_requests, "Please wait five seconds before trying again."}

        :rate_limited ->
          {:too_many_requests,
           "Derpibooru is rate limiting requests. Please try again in a minute."}

        :tag_limit ->
          {:too_many_requests, "Your tag change limit was reached. Please try again later."}

        :not_configured ->
          {:service_unavailable, "Derpibooru tag lookup is not configured."}

        :system_user_missing ->
          {:service_unavailable, "The system account for audit comments is not configured."}

        :unauthorized ->
          {:bad_gateway, "Derpibooru rejected the configured API credentials."}

        :share_failed ->
          {:unprocessable_entity,
           "Could not create a temporary share. Check this image's tag permissions and rating tags."}

        :merge_failed ->
          {:unprocessable_entity, "Could not merge tags. No tags or audit comment were saved."}

        _ ->
          {:bad_gateway,
           "Derpibooru could not be reached or returned an unexpected response. Please try again."}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end
