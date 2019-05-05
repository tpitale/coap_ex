defmodule CoAP.Payload do
  defstruct segments: [], multipart: false, data: <<>>, size: nil

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
      iex> {block, payload.multipart, payload.size}
      {%CoAP.Block{number: 0, more: true, size: 256}, true, 256}

  """
  def segment_at(payload, number \\ nil)

  def segment_at(%__MODULE__{data: <<>>, size: size}, _number),
    do: {<<>>, Block.build({0, false, size}), %__MODULE__{}}

  def segment_at(
        %__MODULE__{data: data, size: size} = payload,
        number
      ) do
    number = number || 0
    offset = size * number
    data_size = byte_size(data)
    part_size = Enum.min([data_size - offset, size])
    more = data_size > offset + part_size

    # TODO: splits into the appropriate segment
    data = data |> :binary.part(offset, part_size)

    block = Block.build({number, more, size})

    {data, block, %{payload | multipart: more}}
  end

  # This is the only time we can set size
  def segment_at(data, size, number) when is_binary(data) do
    %__MODULE__{data: data, size: size} |> segment_at(number)
  end
end
