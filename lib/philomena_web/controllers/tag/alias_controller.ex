defmodule PhilomenaWeb.Tag.AliasController do
  use PhilomenaWeb, :controller

  alias Philomena.Tags.Tag
  alias Philomena.Tags

  plug PhilomenaWeb.CanaryMapPlug, edit: :alias, update: :alias, delete: :alias

  plug :load_and_authorize_resource,
    model: Tag,
    id_name: "tag_id",
    id_field: "slug",
    preload: [:implied_tags, :aliased_tag],
    persisted: true

  def edit(conn, _params) do
    changeset = Tags.change_tag(conn.assigns.tag)
    render(conn, "edit.html", title: "Editing Tag Alias", changeset: changeset)
  end

  def update(conn, params) do
    tag_params = if is_map(params["tag"]), do: params["tag"], else: %{}

    case Tags.alias_tag(conn.assigns.tag, tag_params) do
      {:ok, tag} ->
        conn = moderation_log(conn, details: &log_details/2, data: tag)

        if conn.assigns.ajax? do
          json(conn, %{success: true})
        else
          conn
          |> put_flash(:info, "Tag alias queued.")
          |> redirect(to: ~p"/tags/#{tag}/alias/edit")
        end

      {:error, changeset} ->
        if conn.assigns.ajax? do
          errors =
            Ecto.Changeset.traverse_errors(
              changeset,
              &PhilomenaWeb.ErrorHelpers.translate_error/1
            )

          reason =
            Enum.map_join(errors, "; ", fn {field, messages} ->
              "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"
            end)

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{success: false, error: reason})
        else
          render(conn, "edit.html", changeset: changeset)
        end
    end
  end

  def delete(conn, _params) do
    {:ok, tag} = Tags.unalias_tag(conn.assigns.tag)

    conn
    |> put_flash(:info, "Tag dealias queued.")
    |> moderation_log(details: &log_details/2, data: tag)
    |> redirect(to: ~p"/tags/#{tag}")
  end

  defp log_details(action, tag) do
    body =
      case action do
        :update -> "Aliased tag '#{tag.name}' into '#{tag.aliased_tag.name}'"
        :delete -> "Dealiased tag '#{tag.name}'"
      end

    %{body: body, subject_path: ~p"/tags/#{tag}"}
  end
end
