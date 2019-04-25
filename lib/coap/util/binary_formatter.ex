defmodule CoAP.Util.BinaryFormatter do
  @max_allowed_bytes 1000

  # truncate long values
  def to_hex(<<allowed::binary-size(@max_allowed_bytes), rest::binary>>) do
    to_hex(allowed, [], 0) <> " ... #{@max_allowed_bytes + byte_size(rest)} total bytes"
  end

  def to_hex(bytes) when is_binary(bytes) do
    to_hex(bytes, [], 0)
  end

  def to_hex(nil), do: "nil"

  defp to_hex(<<b::binary-size(1), bytes::binary>>, acc, index) when is_binary(bytes) do
    to_hex(bytes, [Base.encode16(b) | acc], index + 1)
  end

  defp to_hex(<<>>, acc, _byte_index), do: acc |> Enum.reverse() |> Enum.join(" ")
end
