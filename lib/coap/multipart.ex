defmodule CoAP.Multipart do
  # Normalize block1/block2 depending on if this is a request or response

  # In a request:
  # block1 => is the transfer description (number, is there more, size)
  # block2 => "control", or what size the response should be chunked into, client preference, which part of # the response that the server should send back used in subsequent requests
  #
  # In a response:
  # block2 => is the transfer description (number, is there more, size)
  # block1 => "control", or what size subsequent requests should be made at; server preference

  alias CoAP.Block

  # TODO: redefine as description/control based on request/response
  defstruct multipart: false,
            description: nil,
            control: nil,
            more: false,
            number: 0,
            size: 0,
            requested_size: 0,
            requested_number: 0

  def build(_request, nil, nil), do: %__MODULE__{}

  # Request variation
  def build(true, block1, block2) do
    build(Block.build(block1), Block.build(block2))
  end

  # Response variation
  def build(false, block1, block2) do
    build(Block.build(block2), Block.build(block1))
  end

  def build(%Block{} = description, %Block{} = control) do
    %__MODULE__{
      multipart: true,
      description: description,
      control: control,
      more: description.more,
      number: description.number,
      size: description.size,
      requested_number: control.number,
      requested_size: control.size
    }
  end

  def build(nil, %Block{} = control) do
    %__MODULE__{
      multipart: true,
      description: nil,
      control: control,
      requested_number: control.number,
      requested_size: control.size
    }
  end

  def build(%Block{} = description, nil) do
    case {description.more, description.number} do
      {false, 0} ->
        # Return nil if this is the first block, and there are no more
        # as this is not a multipart payload
        nil

      _ ->
        %__MODULE__{
          multipart: true,
          description: description,
          control: nil,
          more: description.more,
          number: description.number,
          size: description.size
        }
    end
  end

  def build(nil, nil), do: %__MODULE__{multipart: false, description: nil, control: nil}

  def as_blocks(true, multipart) do
    %{
      block1: multipart.description |> Block.to_tuple(),
      block2: multipart.control |> Block.to_tuple()
    }
    |> reject_nil_values()
  end

  # TODO: if we get nil here, that's wrong
  def as_blocks(false, multipart) do
    %{
      block1: multipart.control |> Block.to_tuple(),
      block2: multipart.description |> Block.to_tuple()
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(blocks) do
    blocks
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end
