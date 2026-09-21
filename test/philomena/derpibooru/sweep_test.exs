defmodule Philomena.Derpibooru.SweepTest do
  use ExUnit.Case, async: true
  alias Philomena.Derpibooru.Sweep

  test "dimensions must be close in both axes and aspect ratio" do
    image = %{image_width: 1000, image_height: 800}
    assert Sweep.similar_dimensions?(image, %{width: 1000, height: 800})
    assert Sweep.similar_dimensions?(image, %{width: 950, height: 760})
    refute Sweep.similar_dimensions?(image, %{width: 500, height: 400})
    refute Sweep.similar_dimensions?(image, %{width: 950, height: 800})
    refute Sweep.similar_dimensions?(image, %{width: 800, height: 1000})
    refute Sweep.similar_dimensions?(image, %{width: nil, height: 800})
    refute Sweep.similar_dimensions?(image, %{})
    refute Sweep.similar_dimensions?(image, %{width: 1000, height: 0})
  end

  test "failures back off exponentially, never faster than ten seconds" do
    assert Enum.map(1..8, &Sweep.backoff_ms/1) == [
             10_000,
             20_000,
             40_000,
             80_000,
             160_000,
             320_000,
             600_000,
             600_000
           ]

    assert Sweep.backoff_ms(1000) == 600_000
  end
end
