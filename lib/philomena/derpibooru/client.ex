defmodule Philomena.Derpibooru.Client do
  @moduledoc "Server-only, bounded requests to the official Derpibooru API."

  @base "https://derpibooru.org/api/v1/json"

  def configured?, do: Application.get_env(:philomena, :derpibooru_api_key) not in [nil, ""]

  def image(id) when is_integer(id) and id > 0 do
    with {:ok, %{"image" => image}} <- request(:get, "/images/#{id}", []),
         {:ok, candidate} <- candidate(image),
         true <- candidate.id == id do
      {:ok, candidate}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  def reverse(url) do
    with {:ok, %{"images" => images}} when is_list(images) <-
           request(:post, "/search/reverse", url: url, distance: "0.25", limit: "10") do
      candidates = Enum.map(Enum.take(images, 10), &candidate/1)

      if Enum.all?(candidates, &match?({:ok, _}, &1)) do
        {:ok, candidates |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)}
      else
        {:error, :invalid_response}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp request(method, path, params) do
    cache_key = "derpibooru:#{:crypto.hash(:sha256, path <> inspect(params)) |> Base.encode16()}"

    cond do
      not configured?() -> {:error, :not_configured}
      cached("derpibooru:cooldown") != nil -> {:error, :rate_limited}
      body = cached(cache_key) -> JSON.decode(body)
      true -> fetch(method, path, params, cache_key)
    end
  end

  defp fetch(method, path, params, cache_key) do
    # Never log the request, URL, exception or response body: the query carries a secret.
    opts = [
      method: method,
      url: @base <> path,
      params: [key: Application.get_env(:philomena, :derpibooru_api_key)] ++ params,
      headers: [{"accept", "application/json"}, {"user-agent", "PhilomenaTagMerge/1.0"}],
      receive_timeout: 30_000,
      connect_options: [timeout: 5_000],
      max_retries: 0,
      retry: false,
      redirect: false
    ]

    opts = Keyword.merge(opts, Application.get_env(:philomena, :derpibooru_http_options, []))

    case Req.request(opts) do
      {:ok, %{status: 200, body: body} = response} when is_map(body) ->
        # Small cache shared by all app processes; never cache the API key or request URL.
        if ttl = cache_ttl(response), do: cache(cache_key, JSON.encode!(body), ttl)
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %{status: 429} = response} ->
        cache("derpibooru:cooldown", "1", retry_after(response))
        {:error, :rate_limited}

      {:ok, _} ->
        {:error, :upstream}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp cached(key) do
    case Redix.command(:redix, ["GET", key]) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp cache(key, value, seconds), do: Redix.command(:redix, ["SET", key, value, "EX", seconds])

  defp cache_ttl(response) do
    control = response |> Req.Response.get_header("cache-control") |> Enum.join(",")

    cond do
      String.contains?(control, ["no-store", "no-cache"]) ->
        nil

      match = Regex.run(~r/max-age=(\d+)/, control) ->
        case String.to_integer(Enum.at(match, 1)) do
          0 -> nil
          seconds -> min(seconds, 60)
        end

      true ->
        60
    end
  end

  defp retry_after(response) do
    # Req 0.6 returns milliseconds for both numeric and HTTP-date Retry-After values.
    milliseconds = Req.Response.get_retry_after(response) || 60_000
    max(div(milliseconds + 999, 1000), 1)
  rescue
    _ -> 60
  end

  def candidate(%{"id" => id, "tags" => tags} = data)
      when is_integer(id) and id > 0 and is_list(tags) and length(tags) <= 1000 do
    if Enum.all?(tags, &(is_binary(&1) and byte_size(&1) <= 200)) and
         is_map(data["representations"] || %{}) and is_list(data["source_urls"] || []) and
         data["hidden_from_users"] != true and data["deletion_reason"] in [nil, ""] do
      representations = data["representations"] || %{}
      sources = data["source_urls"] || []

      {:ok,
       %{
         id: id,
         width: data["width"],
         height: data["height"],
         url: "https://derpibooru.org/images/#{id}",
         thumbnail: thumbnail_url(representations["thumb"]),
         tags: tags,
         artists: Enum.filter(tags, &String.starts_with?(&1, "artist:")),
         sources: Enum.filter(sources, &https_url?/1)
       }}
    else
      {:error, :not_found}
    end
  end

  def candidate(_), do: {:error, :invalid_response}

  defp thumbnail_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when host in ["derpicdn.net", "derpibooru.org"] ->
        url

      _ ->
        nil
    end
  end

  defp thumbnail_url(_), do: nil

  defp https_url?(url) when is_binary(url),
    do:
      match?(
        %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host),
        URI.parse(url)
      )

  defp https_url?(_), do: false
end
