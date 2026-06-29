defmodule PhilomenaWeb.Api.Json.ImageController do
  use PhilomenaWeb, :controller

  alias Philomena.Images.Image
  alias Philomena.Images
  alias Philomena.Interactions
  alias Philomena.Comments
  alias Philomena.Tags
  alias Philomena.UserStatistics
  alias Philomena.Repo
  import Ecto.Query

  plug PhilomenaWeb.ScraperCachePlug
  plug PhilomenaWeb.ApiRequireAuthorizationPlug when action in [:create, :update]
  plug PhilomenaWeb.UserAttributionPlug when action in [:create, :update]

  plug PhilomenaWeb.ScraperPlug,
       [params_name: "image", params_key: "image"] when action in [:create]

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    image =
      Image
      |> where(id: ^id)
      |> preload([:user, :intensity, :sources, tags: :aliases])
      |> Repo.one()

    case image do
      nil ->
        conn
        |> put_status(:not_found)
        |> text("")

      _ ->
        interactions = Interactions.user_interactions([image], user)

        render(conn, "show.json", image: image, interactions: interactions)
    end
  end

  def update(conn, %{"id" => id, "image" => image_params}) do
    user = conn.assigns.current_user
    attributes = conn.assigns.attributes

    image =
      Image
      |> where(id: ^id)
      |> preload([:user, :locked_tags, :sources, tags: :aliases])
      |> Repo.one()

    case image do
      nil ->
        conn
        |> put_status(:not_found)
        |> text("")

      _ ->
        old_tag_input = Enum.map_join(image.tags, ",", & &1.name)
        params = Map.put(image_params, "old_tag_input", old_tag_input)

        case Images.update_tags(image, attributes, params) do
          {:ok, %{image: {image, added_tags, removed_tags}}} ->
            PhilomenaWeb.Endpoint.broadcast!(
              "firehose",
              "image:tag_update",
              %{
                image_id: image.id,
                added: Enum.map(added_tags, & &1.name),
                removed: Enum.map(removed_tags, & &1.name)
              }
            )

            PhilomenaWeb.Endpoint.broadcast!(
              "firehose",
              "image:update",
              PhilomenaWeb.Api.Json.ImageView.render("show.json", %{
                image: image,
                interactions: []
              })
            )

            Comments.reindex_comments_on_image(image)
            Images.reindex_image(image)
            Tags.reindex_tags(added_tags ++ removed_tags)

            if Enum.any?(added_tags ++ removed_tags) do
              UserStatistics.inc_stat(user, :metadata_updates)
            end

            image = Repo.preload(image, [:sources, tags: :aliases], force: true)
            interactions = Interactions.user_interactions([image], user)

            render(conn, "show.json", image: image, interactions: interactions)

          {:error, :image, changeset, _} ->
            conn
            |> put_status(:bad_request)
            |> render("error.json", changeset: changeset)

          {:error, :check_limits, _error, _} ->
            conn
            |> put_status(:too_many_requests)
            |> text("")
        end
    end
  end

  def create(conn, %{"image" => image_params}) do
    attributes = conn.assigns.attributes

    case Images.create_image(attributes, image_params) do
      {:ok, %{image: image}} ->
        image = Repo.preload(image, tags: :aliases)

        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:create",
          PhilomenaWeb.Api.Json.ImageView.render("show.json", %{image: image, interactions: []})
        )

        render(conn, "show.json", image: image, interactions: [])

      {:error, :image, changeset, _} ->
        conn
        |> put_status(:bad_request)
        |> render("error.json", changeset: changeset)
    end
  end
end
