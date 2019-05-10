defmodule CoAP.Block do
  defstruct number: 0, more: false, size: 0

  # TODO: if more: false, a size_exponent of 0 should be ignored?
  # otherwise size_exponent of 0 results in size: 16

  def build(%__MODULE__{} = block), do: block

  def build({number, more, size}) do
    %__MODULE__{number: number, more: more, size: size}
  end

  def build(nil), do: nil

  def to_tuple(nil), do: nil
  def to_tuple(%__MODULE__{} = block), do: {block.number, block.more, block.size}
  def to_tuple(block) when is_tuple(block), do: block

  def decode(<<number::size(4), more::size(1), size_exponent::size(3)>>),
    do: decode(number, more, size_exponent)

  def decode(<<number::size(12), more::size(1), size_exponent::size(3)>>),
    do: decode(number, more, size_exponent)

  def decode(<<number::size(28), more::size(1), size_exponent::size(3)>>),
    do: decode(number, more, size_exponent)

  def decode(number, more, size_exponent) do
    %__MODULE__{
      number: number,
      more: if(more == 0, do: false, else: true),
      size: trunc(:math.pow(2, size_exponent + 4))
    }
  end

  def encode(%__MODULE__{} = block), do: encode({block.number, block.more, block.size})
  def encode(%{number: number, more: more, size: size}), do: encode({number, more, size})

  def encode({number, more, 0}) do
    encode(number, if(more, do: 1, else: 0), 0)
  end

  def encode({number, more, size}) do
    encode(number, if(more, do: 1, else: 0), trunc(:math.log2(size)) - 4)
  end

  def encode(number, more, size_exponent) when number < 16 do
    <<number::size(4), more::size(1), size_exponent::size(3)>>
  end

  def encode(number, more, size_exponent) when number < 4096 do
    <<number::size(12), more::size(1), size_exponent::size(3)>>
  end

  def encode(number, more, size_exponent) do
    <<number::size(28), more::size(1), size_exponent::size(3)>>
  end
end
