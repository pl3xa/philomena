defmodule Philomena.TagsTest do
  use Philomena.DataCase, async: false

  alias Philomena.Tags
  alias Philomena.Tags.Tag

  defmodule UnavailableQueue do
    def enqueue(_pid, _queue, _worker, _args, _options), do: {:error, :unavailable}
  end

  setup do
    {:ok, source} = Tags.create_tag(%{name: "alias source"})
    %{source: source}
  end

  test "aliases to an existing normalized target and queues the correct direction", %{
    source: source
  } do
    {:ok, target} = Tags.create_tag(%{name: "alias target"})
    assert {:ok, tag} = Tags.alias_tag(source, %{"target_tag" => "  ALIAS_target  "})
    assert tag.aliased_tag_id == target.id
    assert Repo.get!(Tag, source.id).aliased_tag_id == target.id
    assert Repo.get!(Tag, target.id).aliased_tag_id == nil
    assert Repo.aggregate(Tag, :count) == 2

    {:ok, jobs} = Redix.command(:redix, ["LRANGE", "exq:queue:indexing", "0", "-1"])

    assert Enum.any?(jobs, fn job ->
             job = JSON.decode!(job)
             job["class"] == "Philomena.TagAliasWorker" and job["args"] == [source.id, target.id]
           end)
  end

  test "creates a missing target with the normal namespace and category", %{source: source} do
    assert {:ok, tag} = Tags.alias_tag(source, %{"target_tag" => " Artist: New_Artist "})
    target = Repo.get!(Tag, tag.aliased_tag_id)
    assert target.name == "artist:new_artist"
    assert target.namespace == "artist"
    assert target.category == "origin"
    assert target.slug != nil
  end

  test "rejects blank, missing, non-string and multiple targets", %{source: source} do
    for target <- [nil, "", "  ", "\u00a0", [], %{}, 123, "first,second"] do
      assert {:error, changeset} = Tags.alias_tag(source, %{"target_tag" => target})
      assert errors_on(changeset).aliased_tag == ["must specify one non-empty target tag name"]
    end

    assert {:error, _} = Tags.alias_tag(source, %{})
    assert Repo.aggregate(Tag, :count) == 1
    assert Repo.get!(Tag, source.id).aliased_tag_id == nil
  end

  test "rejects aliasing to the normalized source", %{source: source} do
    assert {:error, changeset} = Tags.alias_tag(source, %{"target_tag" => " ALIAS_SOURCE "})
    assert errors_on(changeset).aliased_tag == ["is the same tag as the source"]
    assert Repo.get!(Tag, source.id).aliased_tag_id == nil
  end

  test "rejects a target that is itself aliased", %{source: source} do
    {:ok, destination} = Tags.create_tag(%{name: "destination"})
    {:ok, target} = Tags.create_tag(%{name: "target"})
    target |> change(aliased_tag_id: destination.id) |> Repo.update!()

    assert {:error, changeset} = Tags.alias_tag(source, %{"target_tag" => "target"})

    assert errors_on(changeset).aliased_tag == [
             "is itself aliased and would create a transitive alias"
           ]
  end

  test "rolls back target creation when the source has incoming aliases", %{source: source} do
    {:ok, incoming} = Tags.create_tag(%{name: "incoming"})
    incoming |> change(aliased_tag_id: source.id) |> Repo.update!()

    assert {:error, changeset} = Tags.alias_tag(source, %{"target_tag" => "new target"})
    assert errors_on(changeset).tag == ["has incoming aliases and cannot be aliased"]
    assert Tags.get_tag_by_name("new target") == nil
    assert Repo.get!(Tag, source.id).aliased_tag_id == nil
  end

  test "repeated submissions reuse the target", %{source: source} do
    assert {:ok, first} = Tags.alias_tag(source, %{"target_tag" => "new target"})
    assert {:ok, second} = Tags.alias_tag(first, %{"target_tag" => "new target"})
    assert first.aliased_tag_id == second.aliased_tag_id
    assert Repo.aggregate(Tag, :count) == 2
  end

  test "queue failure is reported accurately and can be retried", %{source: source} do
    previous = Application.fetch_env(:exq, :queue_adapter)
    Application.put_env(:exq, :queue_adapter, UnavailableQueue)

    restore = fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:exq, :queue_adapter, adapter)
        :error -> Application.delete_env(:exq, :queue_adapter)
      end
    end

    on_exit(restore)
    assert {:error, changeset} = Tags.alias_tag(source, %{"target_tag" => "new target"})

    assert errors_on(changeset).aliased_tag == [
             "was saved, but processing could not be queued; please retry"
           ]

    assert Repo.get!(Tag, source.id).aliased_tag_id != nil
    restore.()
    assert {:ok, _} = Tags.alias_tag(Repo.get!(Tag, source.id), %{"target_tag" => "new target"})
  end
end
