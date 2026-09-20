defmodule PhilomenaWeb.Image.DerpibooruTagControllerTest do
  use PhilomenaWeb.ConnCase, async: false
  import Philomena.UsersFixtures
  alias Philomena.{Repo, Tags}
  alias Philomena.Images.Image

  setup %{conn: conn} do
    old_key = Application.get_env(:philomena, :derpibooru_api_key)
    Application.put_env(:philomena, :derpibooru_api_key, "test-only-key")
    Application.put_env(:philomena, :derpibooru_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:philomena, :derpibooru_api_key, old_key)
      Application.delete_env(:philomena, :derpibooru_http_options)
    end)

    {:ok, keys} = Redix.command(:redix, ["KEYS", "derpibooru:*"])
    if keys != [], do: Redix.command(:redix, ["DEL" | keys])
    user = confirmed_user_fixture()
    confirmed_user_fixture(%{name: "system"})

    tags =
      Enum.map(["safe", "pony", "solo"], fn name ->
        {:ok, tag} = Tags.create_tag(%{name: name})
        tag
      end)

    image =
      Repo.insert!(%Image{
        tags: tags,
        image_is_animated: false,
        first_seen_at: DateTime.utc_now(:second),
        image_sha512_hash: String.duplicate("a", 128),
        image_name: "test.png",
        approved: true
      })

    %{
      conn: conn |> log_in_user(user) |> put_req_header("x-requested-with", "XMLHttpRequest"),
      image: image
    }
  end

  test "manual lookup returns a preview without creating a share or leaking credentials", %{
    conn: conn,
    image: image
  } do
    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{image: %{id: 123, tags: ["safe", "new tag"]}})
    )

    conn = post(conn, ~p"/images/#{image}/derpibooru_tags", %{derpibooru_id: "123"})

    assert %{"candidates" => [%{"additions" => ["new tag"], "token" => token}]} =
             json_response(conn, 200)

    assert is_binary(token)
    refute conn.resp_body =~ "test-only-key"

    refute Enum.any?(
             Repo.preload(image, :tags, force: true).tags,
             &String.starts_with?(&1.name, "temp-share:")
           )
  end

  test "reverse lookup shares the local image and forwards its URL", %{conn: conn, image: image} do
    Req.Test.expect(__MODULE__, fn request ->
      request = Plug.Conn.fetch_query_params(request)
      assert request.method == "POST"
      assert request.params["url"] =~ "https://s.plexa.dev/#{image.id}/"
      Req.Test.json(request, %{images: [%{id: 123, tags: ["safe"]}, %{id: 456, tags: ["pony"]}]})
    end)

    conn = post(conn, ~p"/images/#{image}/derpibooru_tags", %{mode: "reverse"})
    assert length(json_response(conn, 200)["candidates"]) == 2

    assert Enum.any?(
             Repo.preload(image, :tags, force: true).tags,
             &String.starts_with?(&1.name, "temp-share:")
           )
  end

  test "rejects invalid IDs and tampered merge tokens", %{conn: conn, image: image} do
    response =
      post(conn, ~p"/images/#{image}/derpibooru_tags", %{derpibooru_id: "https://evil.example"})

    assert json_response(response, 400)["error"] =~ "numeric"
    response = put(conn, ~p"/images/#{image}/derpibooru_tags", %{token: "tampered"})
    assert json_response(response, 422)["error"] =~ "invalid"
  end

  test "throttles successful repeated lookups", %{conn: conn, image: image} do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{image: %{id: 123, tags: ["safe"]}}))
    response = post(conn, ~p"/images/#{image}/derpibooru_tags", %{derpibooru_id: "123"})
    assert response.status == 200
    response = post(conn, ~p"/images/#{image}/derpibooru_tags", %{derpibooru_id: "123"})
    assert json_response(response, 429)["error"] =~ "five seconds"
  end

  test "requires sign-in and metadata permission", %{conn: conn, image: image} do
    anonymous =
      conn |> clear_session() |> post(~p"/images/#{image}/derpibooru_tags", %{mode: "reverse"})

    assert anonymous.status in [302, 403]
    image |> Ecto.Changeset.change(tag_editing_allowed: false) |> Repo.update!()
    denied = post(conn, ~p"/images/#{image}/derpibooru_tags", %{mode: "reverse"})
    assert denied.status == 403
  end

  test "fails cleanly when the key is absent", %{conn: conn, image: image} do
    Application.delete_env(:philomena, :derpibooru_api_key)
    response = post(conn, ~p"/images/#{image}/derpibooru_tags", %{mode: "reverse"})
    assert json_response(response, 503)["error"] =~ "not configured"
  end
end
