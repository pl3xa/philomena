defmodule Mix.Tasks.Derpibooru.Sweep do
  use Mix.Task
  @shortdoc "Run or resume a one-time Derpibooru tag sweep using a checkpoint path"
  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]), do: Philomena.Derpibooru.Sweep.run(Path.expand(path))
  def run(_), do: Mix.raise("Usage: mix derpibooru.sweep /persistent/path/state.json")
end
