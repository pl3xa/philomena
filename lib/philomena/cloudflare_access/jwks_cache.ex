defmodule Philomena.CloudflareAccess.JwksCache do
  @moduledoc """
  Caches the Cloudflare Access JWKS (JWT signing keys) by key ID.

  Keys are cached for one hour. An unknown key ID triggers an immediate
  refetch to pick up key rotation, rate-limited by a cooldown so a flood
  of forged tokens cannot hammer the certs endpoint. If a fetch fails,
  previously fetched keys are kept and retries are subject to the same
  cooldown.
  """

  use GenServer

  @ttl_ms 60 * 60 * 1000
  @refetch_cooldown_ms 30 * 1000
  @call_timeout 10_000
  @fetch_timeout 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: opts[:name] || __MODULE__)
  end

  @doc """
  Returns the signing key for the given key ID, fetching or refreshing
  the JWKS as needed. Never raises, even if the cache is not running.
  """
  @spec get_key(String.t(), String.t()) ::
          {:ok, JOSE.JWK.t()} | {:error, :unknown_kid | :fetch_failed}
  def get_key(certs_url, kid) do
    GenServer.call(__MODULE__, {:get_key, certs_url, kid}, @call_timeout)
  catch
    :exit, _ -> {:error, :fetch_failed}
  end

  @doc """
  Drops all cached keys. Intended for tests.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_key, certs_url, kid}, _from, state) do
    now = System.monotonic_time(:millisecond)

    entry =
      Map.get(state, certs_url, %{keys: %{}, fetched_at: nil, last_refetch_at: nil})
      |> maybe_refetch(certs_url, kid, now)

    reply =
      case Map.fetch(entry.keys, kid) do
        {:ok, jwk} -> {:ok, jwk}
        :error when is_nil(entry.fetched_at) -> {:error, :fetch_failed}
        :error -> {:error, :unknown_kid}
      end

    {:reply, reply, Map.put(state, certs_url, entry)}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{}}
  end

  # A successful scheduled (initial/TTL) fetch does not consume the
  # cooldown, so a later unknown kid can still refetch immediately.
  # Miss-triggered refetches and all failures do consume it.
  defp maybe_refetch(entry, certs_url, kid, now) do
    cond do
      not cooldown_elapsed?(entry, now) ->
        entry

      stale?(entry, now) ->
        fetch_into(entry, certs_url, now, _consume_cooldown = false)

      not Map.has_key?(entry.keys, kid) ->
        fetch_into(entry, certs_url, now, _consume_cooldown = true)

      true ->
        entry
    end
  end

  defp stale?(entry, now) do
    is_nil(entry.fetched_at) or now - entry.fetched_at > @ttl_ms
  end

  defp cooldown_elapsed?(entry, now) do
    is_nil(entry.last_refetch_at) or now - entry.last_refetch_at > @refetch_cooldown_ms
  end

  defp fetch_into(entry, certs_url, now, consume_cooldown) do
    case fetch_jwks(certs_url) do
      {:ok, keys} ->
        last_refetch_at = if consume_cooldown, do: now, else: entry.last_refetch_at
        %{keys: keys, fetched_at: now, last_refetch_at: last_refetch_at}

      {:error, _} ->
        %{entry | last_refetch_at: now}
    end
  end

  defp fetch_jwks(certs_url) do
    fetch_fun = Application.get_env(:philomena, :cf_access_jwks_fetch_fun) || (&default_fetch/1)

    with {:ok, %{"keys" => keys}} when is_list(keys) <- fetch_fun.(certs_url) do
      {:ok,
       keys
       |> Enum.flat_map(fn
         %{"kid" => kid} = jwk when is_binary(kid) ->
           case decode_jwk(jwk) do
             {:ok, key} -> [{kid, key}]
             {:error, _} -> []
           end

         _ ->
           []
       end)
       |> Map.new()}
    else
      _ -> {:error, :fetch_failed}
    end
  end

  defp default_fetch(url) do
    case Req.get(url, receive_timeout: @fetch_timeout, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      _ -> {:error, :fetch_failed}
    end
  end

  defp decode_jwk(jwk_map) do
    {:ok, JOSE.JWK.from_map(jwk_map)}
  rescue
    _ -> {:error, :bad_jwk}
  end
end
