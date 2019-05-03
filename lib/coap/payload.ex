defmodule CoAP.Payload do
  defstruct segments: [], multipart: false, data: <<>>, size: nil, number: 0

  alias CoAP.Block

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
      iex> {_bytes, block, payload} = CoAP.Payload.segment_at(data, 256, 0)
      iex> {block, payload.multipart, payload.size, payload.number}
      {%CoAP.Block{number: 0, more: true, size: 256}, true, 256, 1}

  """
  def segment_at(payload, number \\ nil)

  def segment_at(%__MODULE__{data: <<>>, size: size}, _number),
    do: {<<>>, Block.build({0, false, size}), %__MODULE__{}}

  def segment_at(
        %__MODULE__{data: data, size: size, number: number} = payload,
        requested_number
      ) do
    # if no requested number, use the payload number
    number = requested_number || number
    offset = offset_for(size, number)
    # number = (offset / size) |> round

    data_size = byte_size(data)
    part_size = Enum.min([data_size - offset, size])
    more = data_size > offset + part_size

    # TODO: splits into the appropriate segment
    data = data |> :binary.part(offset, part_size)

    block = Block.build({number, more, size})

    {data, block, %{payload | number: number + 1, multipart: more}}
  end

  # This is the only time we can set size
  def segment_at(data, size, number) when is_binary(data) do
    %__MODULE__{data: data, size: size, number: number || 0} |> segment_at(number)
  end

  defp offset_for(size, number) do
    size * number
  end
end
