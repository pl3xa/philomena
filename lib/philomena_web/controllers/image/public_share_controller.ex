defmodule PhilomenaWeb.Image.PublicShareController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias Philomena.Images.Image

  plug PhilomenaWeb.LimitPlug,
       [time: 5, error: "You may only generate a share link once every 5 seconds."]
       when action in [:create]

  plug PhilomenaWeb.FilterBannedUsersPlug
  plug PhilomenaWeb.UserAttributionPlug
  plug PhilomenaWeb.CanaryMapPlug, create: :edit_metadata

  plug :load_and_authorize_resource,
    model: Image,
    id_name: "image_id",
    persisted: true,
    preload: [:user, :locked_tags, :sources, tags: :aliases]

  def create(conn, _params) do
    case Images.create_public_share(conn.assigns.image, conn.assigns.attributes) do
      {:ok, image} ->
        json(conn, %{url: PhilomenaWeb.ImageView.s3_filename_url(image)})

      _error ->
        conn
        |> Plug.Conn.put_status(:internal_server_error)
        |> json(%{error: "Failed to add public-share tag"})
    end
  end
end
