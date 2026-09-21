defmodule Philomena.Derpibooru.TagMergeTest do
  use Philomena.DataCase, async: false

  import Philomena.UsersFixtures
  alias Philomena.{Images, Tags}
  alias Philomena.Comments.Comment
  alias Philomena.Derpibooru.TagMerge
  alias Philomena.Images.Image
  alias Philomena.TagChanges.TagChange
  alias Philomena.Tags.Tag

  setup do
    user = confirmed_user_fixture(%{name: "editor"})
    system = confirmed_user_fixture(%{name: "system"})

    tags =
      Enum.map(["safe", "pony", "solo"], fn name ->
        {:ok, tag} = Tags.create_tag(%{name: name})
        tag
      end)

    image =
      Repo.insert!(%Image{
        tags: tags,
        image_format: "png",
        image_is_animated: false,
        first_seen_at: DateTime.utc_now(:second),
        image_mime_type: "image/png",
        image_width: 100,
        image_height: 100,
        image_size: 100,
        image_name: "test.png",
        image: "test.png",
        image_sha512_hash: String.duplicate("a", 128),
        approved: true
      })
      |> Repo.preload([:locked_tags, :tags])

    {:ok, ip} = EctoNetwork.INET.cast("127.0.0.1")

    %{
      image: image,
      user: user,
      system: system,
      attribution: [user: user, ip: ip, fingerprint: "test"]
    }
  end

  defp candidate(tags),
    do: %{
      id: 123,
      url: "https://derpibooru.org/images/123",
      tags: tags,
      thumbnail: nil,
      artists: [],
      sources: []
    }

  defp tag_names(image),
    do:
      image
      |> Repo.preload(:tags, force: true)
      |> Map.fetch!(:tags)
      |> Enum.map(& &1.name)
      |> Enum.sort()

  test "sweep requires exactly one dimension-compatible result and attributes merges to system",
       ctx do
    source = candidate(["safe", "sweep addition"]) |> Map.merge(%{width: 100, height: 100})
    attribution = Keyword.put(ctx.attribution, :user, ctx.system)

    assert %{status: "no_match"} =
             Philomena.Derpibooru.Sweep.merge_match(ctx.image, [], attribution)

    assert %{status: "multiple_matches"} =
             Philomena.Derpibooru.Sweep.merge_match(
               ctx.image,
               [source, %{source | id: 124, width: 999}],
               attribution
             )

    assert %{status: "dimensions_differ"} =
             Philomena.Derpibooru.Sweep.merge_match(
               ctx.image,
               [%{source | width: 999}],
               attribution
             )

    assert Repo.aggregate(Comment, :count) == 0

    assert %{status: "merged", tags_added: 1} =
             Philomena.Derpibooru.Sweep.merge_match(ctx.image, [source], attribution)

    assert Repo.one!(TagChange).user_id == ctx.system.id
    assert Repo.one!(Comment).user_id == ctx.system.id
    assert Repo.one!(Comment).body =~ "system"

    assert %{status: "unchanged"} =
             Philomena.Derpibooru.Sweep.merge_match(ctx.image, [source], attribution)

    assert Repo.aggregate(Comment, :count) == 1
  end

  test "sweep checkpoints its snapshot and a completed run cannot run again", ctx do
    old_key = Application.get_env(:philomena, :derpibooru_api_key)
    Application.put_env(:philomena, :derpibooru_api_key, "test-only-key")
    ctx.system |> change(verified: true) |> Repo.update!()
    directory = Path.join(System.tmp_dir!(), "derpi-sweep-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "state.json")

    on_exit(fn ->
      Application.put_env(:philomena, :derpibooru_api_key, old_key)
      File.rm_rf!(directory)
    end)

    state = Philomena.Derpibooru.Sweep.run(path)
    assert state["status"] == "completed"
    assert state["processed"] == 1
    assert state["max_image_id"] == ctx.image.id
    assert state["counts"] == %{"skipped_unavailable" => 1}
    assert JSON.decode!(File.read!(path)) == state
    assert Philomena.Derpibooru.Sweep.run(path) == state
    assert File.read!(path <> ".jsonl") |> String.split("\n", trim: true) |> length() == 1
  end

  test "preview resolves aliases, implications and locks without writing tags", %{
    image: image,
    user: user
  } do
    {:ok, alias_tag} = Tags.create_tag(%{name: "old name"})
    {:ok, target} = Tags.create_tag(%{name: "canonical"})
    {:ok, implied} = Tags.create_tag(%{name: "implied"})
    {:ok, locked} = Tags.create_tag(%{name: "locked"})

    target
    |> Repo.preload(:implied_tags)
    |> change()
    |> put_assoc(:implied_tags, [implied])
    |> Repo.update!()

    alias_tag |> change(aliased_tag_id: target.id) |> Repo.update!()
    image = image |> change() |> put_assoc(:locked_tags, [locked]) |> Repo.update!()
    before_count = Repo.aggregate(Tag, :count)
    result = TagMerge.preview(image, candidate(["safe", "OLD_NAME", "locked", "new tag"]), user)
    assert result.additions == ["canonical", "implied", "new tag"]
    assert result.errors == []
    assert Repo.aggregate(Tag, :count) == before_count
  end

  test "excludes sharing tags including alias and implication targets", %{
    image: image,
    user: user
  } do
    {:ok, public} = Tags.create_tag(%{name: "public-share"})
    {:ok, alias_tag} = Tags.create_tag(%{name: "share alias"})
    {:ok, implies} = Tags.create_tag(%{name: "implies sharing"})
    alias_tag |> change(aliased_tag_id: public.id) |> Repo.update!()

    implies
    |> Repo.preload(:implied_tags)
    |> change()
    |> put_assoc(:implied_tags, [public])
    |> Repo.update!()

    result =
      TagMerge.preview(
        image,
        candidate(["public-share", "temp-share:1:3600", "share alias", "implies sharing"]),
        user
      )

    assert result.additions == ["implies sharing"]
  end

  test "merge uses the same implication pass as the preview and excludes operational tags", ctx do
    {:ok, first} = Tags.create_tag(%{name: "first implication"})
    {:ok, second} = Tags.create_tag(%{name: "second implication"})
    {:ok, third} = Tags.create_tag(%{name: "third implication"})
    {:ok, public} = Tags.create_tag(%{name: "public-share"})

    first
    |> Repo.preload(:implied_tags)
    |> change()
    |> put_assoc(:implied_tags, [second, public])
    |> Repo.update!()

    second
    |> Repo.preload(:implied_tags)
    |> change()
    |> put_assoc(:implied_tags, [third])
    |> Repo.update!()

    preview = TagMerge.preview(ctx.image, candidate([first.name]), ctx.user)
    assert preview.additions == [first.name, second.name]
    assert {:ok, :merged} = TagMerge.merge(ctx.image, ctx.attribution, preview.token)
    refute third.name in tag_names(ctx.image)
    refute public.name in tag_names(ctx.image)
  end

  test "merges once with actor history and an approved system audit even with comments locked",
       ctx do
    image = ctx.image |> change(commenting_allowed: false) |> Repo.update!()
    preview = TagMerge.preview(image, candidate(["safe", "new tag"]), ctx.user)
    assert {:ok, :merged} = TagMerge.merge(image, ctx.attribution, preview.token)
    assert tag_names(image) == ["new tag", "pony", "safe", "solo"]
    comment = Repo.one!(Comment)
    assert comment.user_id == ctx.system.id
    assert comment.approved
    assert comment.body =~ "editor"
    assert comment.body =~ "https://derpibooru.org/images/123"
    assert Repo.one!(TagChange).user_id == ctx.user.id
    assert Repo.get!(Image, image.id).comments_count == 1
    assert {:ok, :unchanged} = TagMerge.merge(image, ctx.attribution, preview.token)
    assert Repo.aggregate(Comment, :count) == 1
  end

  test "preserves edits made after a preview and stale ordinary tag submissions", ctx do
    preview = TagMerge.preview(ctx.image, candidate(["new tag"]), ctx.user)

    assert {:ok, _} =
             Images.update_tags(ctx.image, ctx.attribution, %{
               "old_tag_input" => "safe, pony, solo",
               "tag_input" => "safe, pony, solo, concurrent"
             })

    assert {:ok, :merged} = TagMerge.merge(ctx.image, ctx.attribution, preview.token)

    assert {:ok, _} =
             Images.update_tags(ctx.image, ctx.attribution, %{
               "old_tag_input" => "safe, pony, solo",
               "tag_input" => "safe, pony, solo, other"
             })

    assert tag_names(ctx.image) == ["concurrent", "new tag", "other", "pony", "safe", "solo"]
  end

  test "refreshes a stale diff instead of silently merging a different list", ctx do
    preview = TagMerge.preview(ctx.image, candidate(["first", "second"]), ctx.user)

    assert {:ok, _} =
             Images.update_tags(ctx.image, ctx.attribution, %{
               "old_tag_input" => "safe, pony, solo",
               "tag_input" => "safe, pony, solo, first"
             })

    assert {:error, {:stale, updated}} = TagMerge.merge(ctx.image, ctx.attribution, preview.token)
    assert updated.additions == ["second"]
    assert Repo.aggregate(Comment, :count) == 0
    assert {:ok, :merged} = TagMerge.merge(ctx.image, ctx.attribution, updated.token)
  end

  test "rating conflicts fail without removing existing tags or creating comments", ctx do
    preview = TagMerge.preview(ctx.image, candidate(["explicit", "new tag"]), ctx.user)
    assert preview.errors != []

    assert {:error, {:invalid_tags, _}} =
             TagMerge.merge(ctx.image, ctx.attribution, preview.token)

    assert tag_names(ctx.image) == ["pony", "safe", "solo"]
    assert Tags.get_tag_by_name("new tag") == nil
    assert Repo.aggregate(Comment, :count) == 0
  end

  test "rejects tampered, expired, wrong-user and wrong-image tokens", ctx do
    preview = TagMerge.preview(ctx.image, candidate(["new tag"]), ctx.user)

    assert {:error, :invalid_preview} =
             TagMerge.merge(ctx.image, ctx.attribution, preview.token <> "x")

    assert {:error, :invalid_preview} =
             TagMerge.merge(%{ctx.image | id: ctx.image.id + 1}, ctx.attribution, preview.token)

    assert {:error, :invalid_preview} =
             TagMerge.merge(
               ctx.image,
               Keyword.put(ctx.attribution, :user, ctx.system),
               preview.token
             )

    {:ok, payload} =
      Phoenix.Token.verify(PhilomenaWeb.Endpoint, "derpibooru-tag-preview-v1", preview.token)

    expired =
      Phoenix.Token.sign(PhilomenaWeb.Endpoint, "derpibooru-tag-preview-v1", payload,
        signed_at: System.system_time(:second) - 1000
      )

    assert {:error, :invalid_preview} = TagMerge.merge(ctx.image, ctx.attribution, expired)
  end

  test "rechecks image locks at merge time", ctx do
    preview = TagMerge.preview(ctx.image, candidate(["new tag"]), ctx.user)
    ctx.image |> change(tag_editing_allowed: false) |> Repo.update!()
    assert {:error, :forbidden} = TagMerge.merge(ctx.image, ctx.attribution, preview.token)
    assert Repo.aggregate(Comment, :count) == 0
  end

  test "missing system account prevents any writes", ctx do
    preview = TagMerge.preview(ctx.image, candidate(["new tag"]), ctx.user)
    Repo.delete!(ctx.system)

    assert {:error, :system_user_missing} =
             TagMerge.merge(ctx.image, ctx.attribution, preview.token)

    assert tag_names(ctx.image) == ["pony", "safe", "solo"]
  end

  test "an audit insert failure rolls back tag creation, history and counts", ctx do
    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_derpi_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'audit unavailable'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_derpi_audit BEFORE INSERT ON comments FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_derpi_audit()"
    )

    preview = TagMerge.preview(ctx.image, candidate(["rollback tag"]), ctx.user)

    assert {:error, :merge_failed} = TagMerge.merge(ctx.image, ctx.attribution, preview.token)

    assert tag_names(ctx.image) == ["pony", "safe", "solo"]
    assert Tags.get_tag_by_name("rollback tag") == nil
    assert Repo.aggregate(TagChange, :count) == 0
    assert Repo.get!(Image, ctx.image.id).comments_count == 0
  end
end
