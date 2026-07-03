defmodule Philomena.Markdown do
  @markdown_chars ~r/[\*_\[\]\(\)\^`\%\\~<>#\|]/

  # Escaped forms of the only raw HTML allowed back through: plain,
  # attribute-free <details>/<summary>. Anything with an attribute escapes to
  # a different string and stays inert, so nothing can be smuggled onto them.
  @collapsible_tags [
    {"&lt;details&gt;", "<details>"},
    {"&lt;/details&gt;", "</details>"},
    {"&lt;summary&gt;", "<summary>"},
    {"&lt;/summary&gt;", "</summary>"}
  ]

  # Code spans/blocks must keep displaying these as literal text; the
  # renderer emits no nested <pre>/<code>, so a lazy match is exact.
  @code_segments ~r{<pre.*?</pre>|<code.*?</code>}s

  @doc """
  Converts user-input Markdown to HTML, with the specified map of image
  replacements (which converts ">>1234p" syntax to an embedded image).

  Raw HTML is escaped by the renderer; the exact escaped forms of plain
  <details> and <summary> are then turned back into real elements (outside
  code spans/blocks) to support collapsible sections.
  """
  @spec to_html(String.t(), %{String.t() => String.t()}) :: String.t()
  def to_html(text, replacements) do
    text
    |> Philomena.Native.markdown_to_html(replacements)
    |> allow_collapsible_html()
  end

  defp allow_collapsible_html(html) do
    @code_segments
    |> Regex.split(html, include_captures: true)
    |> Enum.map_join(fn segment ->
      if String.starts_with?(segment, ["<pre", "<code"]) do
        segment
      else
        Enum.reduce(@collapsible_tags, segment, fn {escaped, tag}, acc ->
          String.replace(acc, escaped, tag)
        end)
      end
    end)
  end

  @doc """
  Converts trusted-input Markdown to HTML, with the specified map of image
  replacements (which converts ">>1234p" syntax to an embedded image). This
  function does not strip any raw HTML embedded in the document.
  """
  @spec to_html_unsafe(String.t(), %{String.t() => String.t()}) :: String.t()
  def to_html_unsafe(text, replacements),
    do: Philomena.Native.markdown_to_html_unsafe(text, replacements)

  @doc """
  Escapes special characters in text which is to be rendered as Markdown.
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    @markdown_chars
    |> Regex.replace(text, fn m ->
      "\\#{m}"
    end)
  end
end
