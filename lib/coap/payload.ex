defmodule CoAP.Payload do
  defstruct segments: [], multipart: false, data: <<>>, offset: 0

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

  def to_binary(%__MODULE__{data: data, segments: []}), do: data

  def to_binary(%__MODULE__{segments: segments, data: <<>>}) do
    segments
    |> List.keysort(0)
    |> Enum.map(&elem(&1, 1))
    |> Enum.join(<<>>)
  end

  @doc """
    Extract the next segment of the payload's data given the
    current offset and a requested size

  Examples

      iex> data = StreamData.string(:alphanumeric) |> Enum.take(2048) |> :binary.list_to_bin
      iex> payload = %CoAP.Payload{offset: 1024, data: data}
      iex> {_bytes, number, next_payload} = payload |> CoAP.Payload.next_segment(256)
      iex> {number, next_payload.offset}
      {4, 1280}

  """
  def next_segment(%__MODULE__{data: data, offset: offset} = payload, size) do
    number = (offset / size) |> round

    # TODO: splits into the appropriate segment
    bytes = data |> :binary.part(offset, offset + size)

    {bytes, number, %{payload | offset: offset + size}}
  end
end
