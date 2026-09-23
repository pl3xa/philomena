# One-time, manually invoked migration. Nothing in the application loads this file.
# Preview (read-only):
#   docker compose exec -T app mix run -r scripts/one_time/prefix_date_tags.exs \
#     -e 'OneTime.PrefixDateTags.run()'
# Apply:
#   docker compose exec -T app mix run -r scripts/one_time/prefix_date_tags.exs \
#     -e 'OneTime.PrefixDateTags.run(:apply)'
#
# Matches valid year-first calendar dates with dots, hyphens, or slashes, including
# unpadded months/days. Preserves the spelling: 2025.1.16 -> date:2025.1.16.
# Renames in place, preserving IDs, image taggings, aliases, implications, history,
# and ID-based filters. Destination name/slug collisions abort the entire rename.
# Derived fields and category follow normal tag creation (date: => spoiler).
# Rerun after an interrupted search refresh: already-prefixed dates are reindexed
# too. No database migration, Mix task, worker, or startup hook is registered.

defmodule OneTime.PrefixDateTags do
  import Ecto.Query

  alias Philomena.{Autocomplete, Images, Repo, Tags}
  alias Philomena.Images.Image
  alias Philomena.Tags.Tag
  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search.Api

  def run(mode \\ :dry_run) when mode in [:dry_run, :apply] do
    if mode == :dry_run do
      tags = candidates()
      check_collisions!(tags)

      for tag <- tags do
        IO.puts("#{tag.id}: #{tag.name} -> date:#{tag.name} (spoiler)")
      end

      IO.puts("Dry run: #{length(tags)} tags would be renamed; no changes made.")
    else
      {:ok, count} =
        Repo.transaction(fn ->
          # Prevent a concurrent tag creation/rename from invalidating the collision check.
          Repo.query!("LOCK TABLE tags IN SHARE ROW EXCLUSIVE MODE")
          tags = candidates()
          check_collisions!(tags)

          for tag <- tags do
            tag
            |> Tag.creation_changeset(%{name: "date:" <> tag.name})
            |> Repo.update!()
          end

          length(tags)
        end)

      IO.puts("Renamed #{count} tags. Refreshing search and autocomplete...")
      refresh!()
      IO.puts("Done.")
    end
  end

  def date?(name) do
    case Regex.run(~r/\A([0-9]{4})([.\/-])([0-9]{1,2})\2([0-9]{1,2})\z/, name) do
      [_, year, _, month, day] ->
        match?(
          {:ok, _},
          Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))
        )

      _ ->
        false
    end
  end

  defp candidates do
    Tag
    |> where([t], fragment("? ~ ?", t.name, "^[0-9]{4}[./-][0-9]{1,2}[./-][0-9]{1,2}$"))
    |> order_by(:id)
    |> Repo.all()
    |> Enum.filter(&date?(&1.name))
  end

  defp check_collisions!(tags) do
    names = Enum.map(tags, &("date:" <> &1.name))
    slugs = Enum.map(names, &Philomena.Slug.slug/1)

    collisions =
      Tag
      |> where([t], t.name in ^names or t.slug in ^slugs)
      |> select([t], {t.id, t.name})
      |> Repo.all()

    if collisions != [] do
      raise "Destination tags already exist; resolve collisions before applying: #{inspect(collisions)}"
    end
  end

  defp refresh! do
    dates =
      Tag
      |> where([t], like(t.name, "date:%"))
      |> preload(^Tags.indexing_preloads())
      |> Repo.all()
      |> Enum.filter(&date?(String.replace_prefix(&1.name, "date:", "")))

    # Related tag documents embed alias/implication names. Images using an alias
    # target also embed its aliases, even when the renamed alias has no taggings.
    ids =
      dates
      |> Enum.flat_map(fn tag ->
        [tag | tag.aliases ++ tag.implied_tags ++ tag.implied_by_tags] ++
          List.wrap(tag.aliased_tag)
      end)
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    Tag
    |> where([t], t.id in ^ids)
    |> preload(^Tags.indexing_preloads())
    |> reindex!(Tag)

    image_ids =
      from tagging in "image_taggings",
        where: tagging.tag_id in ^ids,
        select: tagging.image_id

    Image
    |> where([i], i.id in subquery(image_ids))
    |> preload(^Images.indexing_preloads())
    |> reindex!(Image)

    Autocomplete.generate_autocomplete!()
  end

  defp reindex!(query, schema) do
    index = Philomena.SearchPolicy.index_for(schema)

    query
    |> Batch.record_batches()
    |> Enum.each(fn records ->
      lines =
        Enum.flat_map(records, fn record ->
          [%{index: %{_index: index.index_name(), _id: record.id}}, index.as_json(record)]
        end)

      case Api.bulk(Philomena.SearchPolicy.opensearch_url(), lines) do
        {:ok, %{status: 200, body: %{"errors" => false}}} ->
          :ok

        result ->
          raise "Search refresh failed after the database commit. Rerun :apply to retry: #{inspect(result, limit: 10)}"
      end
    end)
  end
end
