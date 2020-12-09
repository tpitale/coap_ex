defmodule CoAP.PayloadTest do
  use ExUnit.Case
  doctest CoAP.Payload

  alias CoAP.Payload

  describe "to_binary/1" do
    test "keeps a unique set of blocks by number" do
      segment = <<0, 0, 0, 0, 1>>

      payload =
        Payload.empty()
        |> Payload.add(0, segment)
        |> Payload.add(0, segment)
        |> Payload.add(1, segment)

      assert segment <> segment == Payload.to_binary(payload)
    end

    test "does not overwrite existing block numbers" do
      segment1 = <<0, 0, 0, 0, 1>>
      segment2 = <<0, 0, 0, 0, 2>>
      segment3 = <<0, 0, 0, 0, 3>>

      payload =
        Payload.empty()
        |> Payload.add(0, segment1)
        |> Payload.add(0, segment2)
        |> Payload.add(1, segment3)

      assert segment1 <> segment3 == Payload.to_binary(payload)
    end
  end
end
