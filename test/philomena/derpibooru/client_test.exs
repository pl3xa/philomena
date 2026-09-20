defmodule Philomena.Derpibooru.ClientTest do
  use ExUnit.Case, async: false
  alias Philomena.Derpibooru.Client

  setup do
    old_key = Application.get_env(:philomena, :derpibooru_api_key)
    Application.put_env(:philomena, :derpibooru_api_key, "test-only-key")
    Application.put_env(:philomena, :derpibooru_http_options, plug: {Req.Test, __MODULE__})
    clear_cache()

    on_exit(fn ->
      Application.put_env(:philomena, :derpibooru_api_key, old_key)
      Application.delete_env(:philomena, :derpibooru_http_options)
      clear_cache()
    end)
  end

  defp clear_cache do
    {:ok, keys} = Redix.command(:redix, ["KEYS", "derpibooru:*"])
    if keys != [], do: Redix.command(:redix, ["DEL" | keys])
  end

  test "manual lookup sends credentials only upstream and returns safe normalized data" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/json/images/123"
      assert conn.params["key"] == "test-only-key"

      Req.Test.json(Plug.Conn.put_resp_header(conn, "cache-control", "max-age=60"), %{
        image: %{
          id: 123,
          tags: ["safe"],
          representations: %{thumb: "https://derpicdn.net/thumb.png"}
        }
      })
    end)

    assert {:ok, image} = Client.image(123)
    assert image.url == "https://derpibooru.org/images/123"
    refute inspect(image) =~ "test-only-key"
    assert {:ok, ^image} = Client.image(123)
  end

  test "reverse lookup returns multiple candidates and supports no matches" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "POST"
      assert conn.params["url"] == "https://s.plexa.dev/test"
      Req.Test.json(conn, %{images: [%{id: 1, tags: ["safe"]}, %{id: 2, tags: ["pony"]}]})
    end)

    assert {:ok, [%{id: 1}, %{id: 2}]} = Client.reverse("https://s.plexa.dev/test")
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{images: []}))
    assert {:ok, []} = Client.reverse("https://s.plexa.dev/other")
  end

  test "handles deleted images, malformed responses, timeouts and authentication errors" do
    for {response, expected} <- [{404, :not_found}, {403, :unauthorized}, {500, :upstream}] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, response, ""))
      assert {:error, ^expected} = Client.image(123)
    end

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :unavailable} = Client.image(123)
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{surprise: true}))
    assert {:error, :invalid_response} = Client.image(123)
  end

  test "backs off across requests after a rate limit" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "120") |> Plug.Conn.send_resp(429, "")
    end)

    assert {:error, :rate_limited} = Client.image(123)
    assert {:error, :rate_limited} = Client.image(456)
    assert {:ok, ttl} = Redix.command(:redix, ["TTL", "derpibooru:cooldown"])
    assert ttl in 119..120
  end

  test "rejects unavailable images and unsafe thumbnail URLs" do
    assert {:error, :not_found} =
             Client.candidate(%{"id" => 1, "tags" => ["safe"], "hidden_from_users" => true})

    assert {:ok, %{thumbnail: nil, sources: []}} =
             Client.candidate(%{
               "id" => 1,
               "tags" => ["safe"],
               "representations" => %{"thumb" => "javascript:alert(1)"},
               "source_urls" => ["javascript:alert(1)"]
             })

    assert {:error, :invalid_response} = Client.candidate(%{"id" => "unexpected", "tags" => []})
  end
end
