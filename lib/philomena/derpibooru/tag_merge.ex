defmodule Philomena.Derpibooru.TagMerge do
  @moduledoc "Read-only tag previews and atomic, attributed, add-only imports."

  import Ecto.Query
  alias Ecto.Changeset
  alias Philomena.{Comments, Images, Notifications, Repo, Tags, Users, UserStatistics}
  alias Philomena.Comments.Comment
  alias Philomena.Images.Image
  alias Philomena.Tags.Tag
  alias PhilomenaWeb.Endpoint

  @salt "derpibooru-tag-preview-v1"
  @max_age 900

  def system_user do
    Users.get_user_by_name(Application.get_env(:philomena, :derpibooru_system_user, "system"))
  end

  def preview(image, candidate, user) do
    image = Repo.preload(image, [:tags, :locked_tags], force: true)
    changeset = proposed_changes(image, candidate.tags)
    additions = names(Changeset.get_field(changeset, :added_tags))
    errors = Enum.map(changeset.errors, fn {_field, {message, _}} -> message end)

    token =
      Phoenix.Token.sign(Endpoint, @salt, %{
        image_id: image.id,
        user_id: user.id,
        candidate: candidate,
        additions: additions
      })

    candidate
    |> Map.drop([:tags])
    |> Map.merge(%{additions: additions, errors: errors, token: token})
  end

  def merge(image, attribution, token) do
    user = attribution[:user]

    with {:ok, %{image_id: image_id, user_id: user_id} = payload} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age),
         true <- image_id == image.id and user_id == user.id,
         %{} = system <- system_user() do
      result = transact(image.id, attribution, system, payload)
      after_merge(result, attribution)
    else
      nil -> {:error, :system_user_missing}
      _ -> {:error, :invalid_preview}
    end
  end

  defp transact(id, attribution, system, payload) do
    Repo.transaction(fn -> merge_locked(id, attribution, system, payload) end)
  rescue
    _error in [Ecto.InvalidChangesetError, Ecto.ConstraintError, Postgrex.Error] ->
      {:error, :merge_failed}
  end

  defp merge_locked(id, attribution, system, payload) do
    image =
      Repo.one!(from i in Image, where: i.id == ^id, lock: "FOR UPDATE")
      |> Repo.preload([:user, :sources, :tags, :locked_tags])

    unless Canada.Can.can?(attribution[:user], :edit_metadata, image),
      do: Repo.rollback(:forbidden)

    current = preview(image, payload.candidate, attribution[:user])

    cond do
      current.additions == [] -> %{image: image, comment: nil, added: []}
      current.additions != payload.additions -> Repo.rollback({:stale, current})
      current.errors != [] -> Repo.rollback({:invalid_tags, current.errors})
      true -> apply_merge(image, attribution, system, payload.candidate, current.additions)
    end
  end

  defp apply_merge(image, attribution, system, candidate, additions) do
    old_names = names(image.tags)

    incoming =
      candidate.tags |> Enum.join(",") |> Tag.parse_tag_list() |> Enum.reject(&reserved?/1)

    attrs = %{
      "old_tag_input" => Enum.join(old_names, ","),
      "tag_input" => Enum.join(old_names ++ incoming, ",")
    }

    case Images.update_tags(image, attribution, attrs,
           defer_side_effects: true,
           excluded_tags: reserved_tags()
         ) do
      {:ok, %{image: {updated, added, []}}} ->
        # Alias/implication edits racing a preview must not silently change its promise.
        if names(added) != additions, do: Repo.rollback(:preview_changed)

        actor = attribution[:user]
        # Escape Markdown punctuation in the actor name; the source URL is server-generated.
        actor_name = Regex.replace(~r/[^\p{L}\p{N}\s]/u, actor.name, fn char -> "\\" <> char end)

        body =
          "User ##{actor.id} (#{actor_name}) merged #{length(added)} tags from " <>
            "[Derpibooru image ##{candidate.id}](#{candidate.url})."

        # A narrowly scoped audit entry, independent of ordinary comment locks/approval.
        comment =
          Ecto.build_assoc(updated, :comments)
          |> Comment.creation_changeset(
            %{"body" => body},
            Keyword.put(attribution, :user, system)
          )
          |> Changeset.put_change(:approved, true)
          |> Repo.insert!()

        Repo.update_all(from(i in Image, where: i.id == ^image.id), inc: [comments_count: 1])
        {:ok, _} = Notifications.create_image_comment_notification(system, updated, comment)
        %{image: updated, comment: comment, added: added}

      {:error, :check_limits, _, _} ->
        Repo.rollback(:tag_limit)

      {:error, :image, changeset, _} ->
        Repo.rollback(
          {:invalid_tags, Enum.map(changeset.errors, fn {_, {message, _}} -> message end)}
        )

      _ ->
        Repo.rollback(:merge_failed)
    end
  end

  defp after_merge({:ok, %{comment: nil}}, _attribution), do: {:ok, :unchanged}

  defp after_merge({:ok, %{image: image, comment: comment, added: added}}, attribution) do
    Images.update_tag_change_limits_after_commit(image, attribution)
    Comments.reindex_comments_on_image(image)
    Comments.reindex_comment(comment)
    Images.reindex_image(image)
    Tags.reindex_tags(added)
    UserStatistics.inc_stat(attribution[:user], :metadata_updates)
    UserStatistics.inc_stat(comment.user_id, :comments_posted)

    image = image |> Repo.reload!() |> Repo.preload([:user, :sources, tags: :aliases])
    comment = Repo.preload(comment, [:user, :image])

    Endpoint.broadcast!("firehose", "image:tag_update", %{
      image_id: image.id,
      added: names(added),
      removed: []
    })

    Endpoint.broadcast!(
      "firehose",
      "image:update",
      PhilomenaWeb.Api.Json.ImageView.render("show.json", %{image: image, interactions: []})
    )

    Endpoint.broadcast!(
      "firehose",
      "comment:create",
      PhilomenaWeb.Api.Json.CommentView.render("show.json", %{comment: comment})
    )

    {:ok, :merged}
  end

  defp after_merge(error, _attribution), do: error

  def proposed_changes(image, remote_names) do
    normalized =
      remote_names |> Enum.join(",") |> Tag.parse_tag_list() |> Enum.reject(&reserved?/1)

    existing =
      Repo.all(
        from t in Tag,
          where: t.name in ^normalized,
          preload: [:implied_tags, aliased_tag: :implied_tags]
      )
      |> Map.new(&{&1.name, &1})

    resolved =
      normalized
      |> Enum.with_index(1)
      |> Enum.map(fn {name, index} ->
        case existing[name] do
          nil ->
            %Tag{}
            |> Tag.creation_changeset(%{name: name})
            |> Changeset.apply_changes()
            |> Map.merge(%{id: -index, implied_tags: []})

          tag ->
            tag.aliased_tag || tag
        end
      end)

    excluded =
      (resolved ++ Enum.flat_map(resolved, & &1.implied_tags)) |> Enum.filter(&reserved?(&1.name))

    Image.tag_changeset(
      image,
      %{},
      image.tags,
      image.tags ++ resolved,
      image.locked_tags ++ excluded
    )
  end

  defp reserved?(name), do: name == "public-share" or String.starts_with?(name, "temp-share:")

  defp reserved_tags,
    do: Repo.all(from t in Tag, where: t.name == "public-share" or like(t.name, "temp-share:%"))

  defp names(tags), do: tags |> Enum.map(& &1.name) |> Enum.sort()
end
