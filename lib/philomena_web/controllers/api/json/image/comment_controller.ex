defmodule PhilomenaWeb.Api.Json.Image.CommentController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.Api.Json.CommentView
  alias Philomena.Images.Image
  alias Philomena.Images
  alias Philomena.Comments
  alias Philomena.UserStatistics
  alias Philomena.Repo
  import Ecto.Query

  plug PhilomenaWeb.ApiRequireAuthorizationPlug
  plug PhilomenaWeb.UserAttributionPlug

  def create(conn, %{"image_id" => image_id, "comment" => comment_params}) do
    image =
      Image
      |> where(id: ^image_id)
      |> Repo.one()

    cond do
      is_nil(image) or image.hidden_from_users ->
        conn
        |> put_status(:not_found)
        |> text("")

      not image.commenting_allowed ->
        conn
        |> put_status(:forbidden)
        |> text("")

      true ->
        case Comments.create_comment(image, conn.assigns.attributes, comment_params) do
          {:ok, %{comment: comment}} ->
            comment = Repo.preload(comment, [:image, :user])

            PhilomenaWeb.Endpoint.broadcast!(
              "firehose",
              "comment:create",
              CommentView.render("show.json", %{comment: comment})
            )

            Comments.reindex_comment(comment)
            Images.reindex_image(image)

            if comment.approved do
              UserStatistics.inc_stat(conn.assigns.current_user, :comments_posted)
            else
              Comments.report_non_approved(comment)
            end

            conn
            |> put_status(:created)
            |> put_view(CommentView)
            |> render("show.json", comment: comment)

          {:error, :comment, changeset, _} ->
            conn
            |> put_status(:bad_request)
            |> put_view(CommentView)
            |> render("error.json", changeset: changeset)

          {:error, _operation, _value, _changes} ->
            conn
            |> put_status(:internal_server_error)
            |> text("")
        end
    end
  end
end
