defmodule CoAP.Util.BinaryFormatter do
  def to_hex(bytes) when is_binary(bytes) do
    to_hex(bytes, [], 0)
  end

  def to_hex(nil), do: "nil"

  defp to_hex(<<b::binary-size(1), bytes::binary>>, acc, index) when is_binary(bytes) do
    to_hex(bytes, [Base.encode16(b) | acc], index + 1)
  end

  defp to_hex(<<>>, acc, _byte_index), do: acc |> Enum.reverse() |> Enum.join(" ")
end
