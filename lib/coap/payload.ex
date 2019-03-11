defmodule CoAP.Payload do
  defstruct segments: [], multipart: false

  def empty(), do: %__MODULE__{}

  def add(nil, segment) do
    %__MODULE__{
      multipart: false,
      segments: [{0, segment}]
    }
  end

  def add(%__MODULE__{segments: segments}, number, segment) do
    %__MODULE__{
      multipart: true,
      segments: [{number, segment} | segments]
    }
  end

  def to_binary(%__MODULE__{segments: segments}) do
    segments
    |> List.keysort(0)
    |> Enum.map(&elem(&1, 1))
    |> Enum.join(<<>>)
  end

  def to_segments(payload, number, size) do
    # TODO: splits into the appropriate segment
  end
end
