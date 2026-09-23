defmodule Philomena.Derpibooru.Sweep do
  @moduledoc "A checkpointed, one-time reverse-search sweep. Never scheduled automatically."

  import Ecto.Query
  alias Philomena.{Images, Repo}
  alias Philomena.Images.{Image, TempShare}
  alias Philomena.Derpibooru.{Client, TagMerge}

  @interval 10_000
  @max_attempts 6

  def similar_dimensions?(%{image_width: width, image_height: height}, candidate) do
    other_width = candidate[:width]
    other_height = candidate[:height]

    if Enum.all?([width, height, other_width, other_height], &(is_integer(&1) and &1 > 0)) do
      close?(width, other_width, 0.10) and close?(height, other_height, 0.10) and
        close?(width / height, other_width / other_height, 0.02)
    else
      false
    end
  end

  defp close?(a, b, tolerance), do: abs(a - b) <= max(a, b) * tolerance + 1.0e-9

  def backoff_ms(failures),
    do: min(@interval * Integer.pow(2, min(max(failures - 1, 0), 6)), 600_000)

  def run(path) do
    unless Client.configured?(), do: raise("Derpibooru API key is not configured")
    system = TagMerge.system_user() || raise("System user is missing")
    unless system.verified, do: raise("System user must be verified for the sweep")
    {:ok, ip} = EctoNetwork.INET.cast("127.0.0.1")
    attribution = [user: system, ip: ip, fingerprint: "derpibooru-one-time-sweep"]

    # Session-level lock excludes another sweep, even with a different checkpoint file.
    Repo.checkout(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_lock(73812, 901)").rows do
          [[true]] ->
            try do
              loop(load_or_initialize(path), path, attribution)
            after
              Repo.query!("SELECT pg_advisory_unlock(73812, 901)")
            end

          _ ->
            raise("Another Derpibooru sweep is already running")
        end
      end,
      timeout: :infinity
    )
  end

  # The checkpoint path is supplied by the operator through the Mix task.
  # sobelow_skip ["Traversal.FileModule"]
  defp load_or_initialize(path) do
    if File.exists?(path) do
      JSON.decode!(File.read!(path))
    else
      max_id = Repo.aggregate(Image, :max, :id) || 0

      state = %{
        "max_image_id" => max_id,
        "total_images" => Repo.aggregate(from(i in Image, where: i.id <= ^max_id), :count),
        "last_image_id" => 0,
        "processed" => 0,
        "counts" => %{},
        "consecutive_failures" => 0,
        "next_request_at_ms" => 0,
        "started_at" => timestamp(),
        "status" => "running"
      }

      save(path, state)
    end
  end

  defp loop(%{"status" => "completed"} = state, _path, _attribution), do: state

  defp loop(state, path, attribution) do
    if File.exists?(path <> ".stop") do
      save(path, Map.put(state, "status", "paused"))
    else
      image =
        Repo.one(
          from i in Image,
            where: i.id > ^state["last_image_id"] and i.id <= ^state["max_image_id"],
            order_by: i.id,
            limit: 1,
            preload: [:user, :sources, :tags, :locked_tags]
        )

      if image do
        state = state |> Map.put("current_image_id", image.id) |> Map.put("status", "running")
        save(path, state)
        {outcome, state} = process_image(image, attribution, state, path)
        finish_image(state, outcome, image.id, path) |> loop(path, attribution)
      else
        state
        |> Map.put("status", "completed")
        |> Map.put("finished_at", timestamp())
        |> then(&save(path, &1))
      end
    end
  end

  defp process_image(image, attribution, state, path) do
    if image.hidden_from_users or image.destroyed_content == true or not image.processed or
         not Canada.Can.can?(attribution[:user], :edit_metadata, image) do
      {%{status: "skipped_unavailable"}, state}
    else
      search(image, attribution, state, path, 1)
    end
  end

  defp share_url(image, attribution) do
    now = System.system_time(:second)

    valid_tag =
      Enum.find(image.tags, fn tag ->
        String.starts_with?(tag.name, "temp-share:") and
          not TempShare.expired_tag?(tag.name, now + 1200)
      end)

    case valid_tag && Regex.run(~r/\Atemp-share:(\d+):(\d+)\z/, valid_tag.name) do
      [_, issued, validity] ->
        {:ok, TempShare.url(image, String.to_integer(issued), String.to_integer(validity))}

      _ ->
        Images.create_temp_share(image, attribution)
    end
  end

  defp search(image, attribution, state, path, attempt) do
    wait_until(max(state["next_request_at_ms"], now_ms() + cooldown_ms()))
    fresh = image |> Repo.reload!() |> Repo.preload([:user, :sources, :tags, :locked_tags])

    cond do
      fresh.image_sha512_hash != image.image_sha512_hash ->
        {%{status: "image_changed"}, state}

      not Canada.Can.can?(attribution[:user], :edit_metadata, fresh) ->
        {%{status: "skipped_unavailable"}, state}

      true ->
        # Reissue shares after long Retry-After delays instead of searching expired URLs.
        case share_url(fresh, attribution) do
          {:ok, url} -> request(image, url, attribution, state, path, attempt)
          _ -> {%{status: "share_failed"}, state}
        end
    end
  end

  defp request(image, url, attribution, state, path, attempt) do
    state =
      state |> Map.put("attempt", attempt) |> Map.put("next_request_at_ms", now_ms() + 45_000)

    save(path, state)

    case Client.reverse(url) do
      {:ok, candidates} ->
        state =
          state
          |> Map.put("consecutive_failures", 0)
          |> Map.delete("last_error")
          |> Map.put("next_request_at_ms", now_ms() + @interval)

        save(path, state)
        {merge_match(image, candidates, attribution), state}

      {:error, {:unavailable_candidates, count}} ->
        state =
          state
          |> Map.put("consecutive_failures", 0)
          |> Map.delete("last_error")
          |> Map.put("next_request_at_ms", now_ms() + @interval)

        save(path, state)
        status = if count > 1, do: "multiple_matches", else: "unavailable_match"
        {%{status: status, candidate_count: count, includes_unavailable: true}, state}

      {:error, reason} when reason in [:unauthorized, :not_configured] ->
        save(
          path,
          state
          |> Map.put("status", "paused_credentials")
          |> Map.put("last_error", to_string(reason))
        )

        raise("Sweep paused because Derpibooru credentials were rejected")

      {:error, reason} ->
        failures = state["consecutive_failures"] + 1
        delay = max(backoff_ms(failures), cooldown_ms())

        state =
          state
          |> Map.put("consecutive_failures", failures)
          |> Map.put("next_request_at_ms", now_ms() + delay)
          |> Map.put("last_error", to_string(reason))

        save(path, state)

        IO.puts(
          JSON.encode!(%{
            image_id: image.id,
            attempt: attempt,
            error: reason,
            retry_in_seconds: div(delay, 1000)
          })
        )

        if attempt < @max_attempts do
          search(image, attribution, state, path, attempt + 1)
        else
          {%{status: "search_failed", reason: to_string(reason)}, state}
        end
    end
  end

  def merge_match(_image, [], _attribution), do: %{status: "no_match"}

  def merge_match(image, [candidate], attribution) do
    fresh = Repo.get!(Image, image.id)

    cond do
      fresh.image_sha512_hash != image.image_sha512_hash ->
        %{status: "image_changed"}

      not similar_dimensions?(fresh, candidate) ->
        %{status: "dimensions_differ", derpibooru_id: candidate.id}

      true ->
        preview = TagMerge.preview(fresh, candidate, attribution[:user])

        cond do
          preview.errors != [] ->
            %{status: "tag_conflict", derpibooru_id: candidate.id, errors: preview.errors}

          preview.additions == [] and preview.removals == [] ->
            %{status: "unchanged", derpibooru_id: candidate.id}

          true ->
            case TagMerge.merge(fresh, attribution, preview.token) do
              {:ok, :merged} ->
                %{
                  status: "merged",
                  derpibooru_id: candidate.id,
                  tags_added: length(preview.additions),
                  tags_removed: length(preview.removals)
                }

              {:ok, :unchanged} ->
                %{status: "unchanged", derpibooru_id: candidate.id}

              {:error, _} ->
                %{status: "merge_failed", derpibooru_id: candidate.id}
            end
        end
    end
  end

  def merge_match(_image, candidates, _attribution),
    do: %{status: "multiple_matches", candidates: Enum.map(candidates, & &1.id)}

  # The event log path derives only from the operator-supplied checkpoint path.
  # sobelow_skip ["Traversal.FileModule"]
  defp finish_image(state, outcome, image_id, path) do
    event = Map.merge(outcome, %{image_id: image_id, at: timestamp()})
    line = JSON.encode!(event)
    File.write!(path <> ".jsonl", line <> "\n", [:append])
    IO.puts(line)

    state
    |> Map.put("last_image_id", image_id)
    |> Map.update!("processed", &(&1 + 1))
    |> Map.update!("counts", &Map.update(&1, outcome.status, 1, fn count -> count + 1 end))
    |> Map.put("last_result", JSON.decode!(line))
    |> then(&save(path, &1))
  end

  # The checkpoint path is supplied by the operator through the Mix task.
  # sobelow_skip ["Traversal.FileModule"]
  defp save(path, state) do
    state = Map.put(state, "updated_at", timestamp())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", JSON.encode!(state))
    File.chmod!(path <> ".tmp", 0o600)
    File.rename!(path <> ".tmp", path)
    state
  end

  defp cooldown_ms do
    case Redix.command(:redix, ["PTTL", "derpibooru:cooldown"]) do
      {:ok, ttl} when ttl > 0 -> ttl
      _ -> 0
    end
  end

  defp wait_until(time) do
    remaining = time - now_ms()

    if remaining > 0 do
      Process.sleep(min(remaining, 30_000))
      wait_until(time)
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
  defp timestamp, do: DateTime.utc_now(:second) |> DateTime.to_iso8601()
end
