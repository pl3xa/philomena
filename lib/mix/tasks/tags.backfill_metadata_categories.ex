defmodule Mix.Tasks.Tags.BackfillMetadataCategories do
  use Mix.Task
  import Ecto.Query

  alias Philomena.{Images, Repo, Tags}
  alias Philomena.Images.Image
  alias Philomena.Tags.Tag
  alias PhilomenaQuery.Search

  @shortdoc "Categorize metadata tags as spoilers and refresh affected search records"
  @requirements ["app.start"]

  @impl Mix.Task
  def run([]) do
    matches =
      Enum.reduce(Tag.metadata_prefixes(), dynamic(false), fn prefix, query ->
        pattern = prefix <> "%"
        dynamic([t], ^query or like(t.name, ^pattern))
      end)

    tags = where(Tag, ^matches)

    {count, _} =
      tags
      |> where([t], is_nil(t.category) or t.category != "spoiler")
      |> Repo.update_all(set: [category: "spoiler", updated_at: DateTime.utc_now(:second)])

    Mix.shell().info("Updated #{count} metadata tags")

    # Reindex every matching record even on reruns, so an interrupted index refresh is recoverable.
    tags
    |> preload(^Tags.indexing_preloads())
    |> Search.reindex(Tag)

    tag_ids = select(tags, [t], t.id)

    image_ids =
      from tagging in "image_taggings",
        where: tagging.tag_id in subquery(tag_ids),
        select: tagging.image_id

    Image
    |> where([i], i.id in subquery(image_ids))
    |> preload(^Images.indexing_preloads())
    |> Search.reindex(Image)

    Mix.shell().info("Metadata tag and image search records refreshed")
  end

  def run(_), do: Mix.raise("Usage: mix tags.backfill_metadata_categories")
end
