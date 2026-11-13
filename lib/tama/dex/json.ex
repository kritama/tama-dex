defmodule Tama.Dex.JSON do
  @moduledoc false

  # Canonical JSON and JSON Pointer helpers.
  #
  # Canonical JSON sorts object keys by their UTF-8 bytes and has no
  # insignificant whitespace. Strings, numbers and escapes are encoded by Jason,
  # so the same term always gives the same bytes. Digests and stored schemas
  # use this form, and changing it needs a new index schema version.

  @doc "Encodes a JSON term as canonical JSON."
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> canonicalize() |> Jason.encode!()

  @doc """
  Whether `term` is JSON data: maps with UTF-8 string keys, lists, UTF-8
  strings, numbers, booleans and `nil`.
  """
  @spec data?(term()) :: boolean()
  def data?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and String.valid?(key) and data?(value) end)
  end

  def data?(list) when is_list(list), do: list_data?(list)
  def data?(value) when is_binary(value), do: String.valid?(value)
  def data?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  def data?(_value), do: false

  # Also rejects improper lists.
  defp list_data?([]), do: true
  defp list_data?([head | tail]), do: data?(head) and list_data?(tail)
  defp list_data?(_tail), do: false

  @doc "The lowercase hex SHA-256 of `data`."
  @spec sha256(iodata()) :: String.t()
  def sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  @doc "Builds a JSON Pointer (RFC 6901) from path segments."
  @spec pointer([String.t() | non_neg_integer()]) :: String.t()
  def pointer(segments) do
    Enum.map_join(segments, fn segment -> "/" <> escape(segment) end)
  end

  @doc "Resolves a JSON Pointer against `document`."
  @spec resolve(term(), String.t()) :: {:ok, term()} | :error
  def resolve(document, ""), do: {:ok, document}

  def resolve(document, "/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&unescape/1)
    |> Enum.reduce_while({:ok, document}, &step/2)
  end

  def resolve(_document, _pointer), do: :error

  defp step(key, {:ok, map}) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:cont, {:ok, value}}
      :error -> {:halt, :error}
    end
  end

  defp step(key, {:ok, list}) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 and index < length(list) -> {:cont, {:ok, Enum.at(list, index)}}
      _other -> {:halt, :error}
    end
  end

  defp step(_key, _value), do: {:halt, :error}

  defp escape(segment) when is_integer(segment), do: Integer.to_string(segment)

  defp escape(segment) do
    segment |> String.replace("~", "~0") |> String.replace("/", "~1")
  end

  defp unescape(segment) do
    segment |> String.replace("~1", "/") |> String.replace("~0", "~")
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
