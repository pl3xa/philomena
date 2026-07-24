defmodule Philomena.Images.TempShare do
  @moduledoc """
  Temporary share URLs served by the s.plexa.dev worker.

  A `temp-share:x:y` tag (x = unix issue time, y = validity seconds) opts an
  image into time-limited public access. The URL secret is derived from the
  image's sha512 hash plus the tag values, so the worker can validate it
  without any shared state.
  """

  alias Philomena.Images.Image

  @validity 3600
  @host "s.plexa.dev"
  @tag_re ~r/\Atemp-share:(\d+):(\d+)\z/

  def validity, do: @validity

  @spec tag_name(integer()) :: String.t()
  def tag_name(unix_now), do: "temp-share:#{unix_now}:#{@validity}"

  @spec short_secret(String.t(), integer(), integer()) :: String.t()
  def short_secret(sha512_hash, x, y) do
    :crypto.hash(:sha256, "#{sha512_hash}:#{x}:#{y}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @spec url(Image.t(), integer(), integer()) :: String.t()
  def url(%Image{} = image, x, y) do
    filename =
      image.image_name
      |> to_string()
      |> String.split("?", parts: 2)
      |> hd()
      |> URI.encode()

    "https://#{@host}/#{image.id}/#{short_secret(image.image_sha512_hash, x, y)}/#{filename}"
  end

  @spec expired_tag?(String.t(), integer()) :: boolean()
  def expired_tag?(tag_name, unix_now) do
    case Regex.run(@tag_re, tag_name) do
      [_, x, y] -> unix_now >= String.to_integer(x) + String.to_integer(y)
      _ -> false
    end
  end
end
