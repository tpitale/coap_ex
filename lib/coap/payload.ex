defmodule CoAP.Payload do
  defstruct segments: [], multipart: false, data: <<>>, offset: 0

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
      iex> payload = %CoAP.Payload{offset: 1024, data: data}
      iex> {_bytes, block, next_payload} = payload |> CoAP.Payload.next_segment(256)
      iex> {block, next_payload.offset, next_payload.multipart}
      {%CoAP.Block{number: 4, more: true, size: 256}, 1280, true}

      iex> data = <<>>
      iex> payload = %CoAP.Payload{offset: 0, data: data}
      iex> payload |> CoAP.Payload.next_segment(256)
      {
        <<>>,
        %CoAP.Block{number: 0, more: false, size: 256},
        %CoAP.Payload{data: <<>>, offset: 0, segments: [], multipart: false}
      }

  """
  def next_segment(data, size) when is_binary(data) do
    %__MODULE__{data: data, offset: 0} |> next_segment(size)
  end

  def next_segment(%__MODULE__{data: <<>>}, size),
    do: {<<>>, Block.build({0, false, size}), %__MODULE__{}}

  def next_segment(%__MODULE__{data: data, offset: offset} = payload, size) do
    data_size = byte_size(data)
    number = (offset / size) |> round
    part_size = Enum.min([data_size - offset, size])
    new_offset = offset + part_size
    more = data_size > new_offset

    # TODO: splits into the appropriate segment
    data = data |> :binary.part(offset, part_size)

    block = Block.build({number, more, size})

    {data, block, %{payload | offset: new_offset, multipart: more}}
  end
end
