defmodule Tama.Dex.Text do
  @moduledoc false

  @doc """
  Cuts text to at most `max` bytes on a character boundary, ending a cut
  with `...`.
  """
  @spec bound(String.t(), pos_integer()) :: String.t()
  def bound(text, max) when byte_size(text) <= max, do: text

  def bound(text, max) do
    prefix = binary_part(text, 0, max - 3)

    valid =
      case :unicode.characters_to_binary(prefix) do
        {:incomplete, valid, _rest} -> valid
        valid when is_binary(valid) -> valid
      end

    valid <> "..."
  end
end
