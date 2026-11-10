defmodule AshPaper.Canonical do
  @moduledoc "Sorted-key JSON and its SHA-256, so equal data always hashes equally."

  @spec encode(term()) :: String.t()
  def encode(value), do: value |> sort() |> Jason.encode!()

  @spec hash(term()) :: String.t()
  def hash(value), do: sha256(encode(value))

  @spec sha256(iodata()) :: String.t()
  def sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  @doc "The HMAC of the data under `key`, for hashes of guessable values."
  @spec keyed_hash(binary(), term()) :: String.t()
  def keyed_hash(key, value) when is_binary(key) and byte_size(key) >= 16,
    do: :hmac |> :crypto.mac(:sha256, key, encode(value)) |> Base.encode16(case: :lower)

  defp sort(%_{} = struct), do: struct

  defp sort(%{} = map),
    do:
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> {to_string(k), sort(v)} end)
      |> Jason.OrderedObject.new()

  defp sort(list) when is_list(list), do: Enum.map(list, &sort/1)
  defp sort(other), do: other
end
