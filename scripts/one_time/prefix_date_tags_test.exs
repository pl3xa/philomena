# Run explicitly against the test stack:
#   MIX_ENV=test mix test scripts/one_time/prefix_date_tags_test.exs
Code.require_file("prefix_date_tags.exs", __DIR__)

defmodule OneTime.PrefixDateTagsTest do
  use Philomena.DataCase, async: false

  import ExUnit.CaptureIO
  alias OneTime.PrefixDateTags
  alias Philomena.Tags
  alias Philomena.Tags.Tag

  test "recognizes complete calendar dates without normalizing their spelling" do
    for name <- ["2026.09.23", "2025.1.16", "2024-02-29", "2025/1/2"] do
      assert PrefixDateTags.date?(name)
    end

    for name <- [
          "2025.02.29",
          "2026.13.1",
          "2026.04.31",
          "2026.0.1",
          "2026.1.0",
          "2026.1-2",
          "2026",
          "09.23.2026",
          "date:2026.09.23",
          "originalfilename:2026.09.23.png",
          "art from 2026.09.23"
        ] do
      refute PrefixDateTags.date?(name)
    end
  end

  test "dry run shows the plan without changing tags or autocomplete" do
    {:ok, tag} = Tags.create_tag(%{name: "2025.1.16"})
    tag = Repo.reload!(tag)
    autocomplete = Philomena.Autocomplete.get_autocomplete()

    assert capture_io(fn -> PrefixDateTags.run() end) =~ "2025.1.16 -> date:2025.1.16"
    assert Repo.get!(Tag, tag.id) == tag
    assert Philomena.Autocomplete.get_autocomplete() == autocomplete
  end

  test "a destination collision aborts all renames" do
    {:ok, first} = Tags.create_tag(%{name: "2025.1.15"})
    {:ok, second} = Tags.create_tag(%{name: "2025.1.16"})
    {:ok, _existing} = Tags.create_tag(%{name: "date:2025.1.16"})
    first = Repo.reload!(first)
    second = Repo.reload!(second)

    for mode <- [:dry_run, :apply] do
      assert_raise RuntimeError, ~r/Destination tags already exist/, fn ->
        PrefixDateTags.run(mode)
      end
    end

    assert Repo.get!(Tag, first.id) == first
    assert Repo.get!(Tag, second.id) == second
  end

  test "renames in place, refreshes related search records, and safely reruns" do
    {:ok, date} = Tags.create_tag(%{name: "2024.2.29"})
    {:ok, date_alias} = Tags.create_tag(%{name: "2025-01-16"})
    {:ok, target} = Tags.create_tag(%{name: "ordinary target"})
    {:ok, implying} = Tags.create_tag(%{name: "ordinary implication"})
    date_alias |> change(aliased_tag_id: target.id) |> Repo.update!()
    Repo.insert_all("tags_implied_tags", [%{tag_id: implying.id, implied_tag_id: date.id}])

    untouched =
      for name <- ["2025.02.29", "originalfilename:2026.09.23.png", "date:2023.1.1"] do
        {:ok, tag} = Tags.create_tag(%{name: name})
        Repo.reload!(tag)
      end

    image =
      Repo.insert!(%Philomena.Images.Image{
        tags: [date, target],
        image_format: "png",
        image_is_animated: false,
        first_seen_at: DateTime.utc_now(:second),
        image_mime_type: "image/png",
        image_width: 100,
        image_height: 100,
        image_size: 100,
        image_name: "date-migration.png",
        image: "date-migration.png",
        image_sha512_hash: String.duplicate("a", 128),
        approved: true
      })

    for count <- [2, 0] do
      assert capture_io(fn -> PrefixDateTags.run(:apply) end) =~ "Renamed #{count} tags."

      for tag <- [date, date_alias] do
        updated = Repo.get!(Tag, tag.id)
        assert updated.name == "date:" <> tag.name
        assert updated.slug == Philomena.Slug.slug(updated.name)
        assert updated.category == "spoiler"
        assert updated.images_count == tag.images_count
        assert updated.name_in_namespace == updated.name
        assert indexed("tags", tag.id)["name"] == updated.name
      end

      assert Repo.get!(Tag, date_alias.id).aliased_tag_id == target.id

      assert Repo.preload(image, :tags).tags |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([date.id, target.id])

      assert indexed("tags", target.id)["aliases"] == ["date:2025-01-16"]
      assert indexed("tags", implying.id)["implied_tags"] == ["date:2024.2.29"]
      indexed_image = indexed("images", image.id)
      assert indexed_image["spoiler_tag_count"] == 1
      assert "date:2024.2.29" in indexed_image["namespaced_tags"]["name"]
      assert "date:2025-01-16" in indexed_image["namespaced_tags"]["name"]
      refute "2024.2.29" in indexed_image["namespaced_tags"]["name"]
      assert Philomena.Autocomplete.get_autocomplete() != nil

      for tag <- untouched, do: assert(Repo.get!(Tag, tag.id) == tag)
    end
  end

  defp indexed(index, id) do
    response = Req.get!("#{Philomena.SearchPolicy.opensearch_url()}/#{index}/_doc/#{id}")
    assert response.status == 200
    response.body["_source"]
  end
end
