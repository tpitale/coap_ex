defmodule CoAP.Block do
  defstruct number: 0, more: false, size: 0

  @type t :: %__MODULE__{number: integer, more: boolean, size: integer}
  @type tuple_t :: {integer, boolean, integer}
  @type binary_t_small :: <<_::8>>
  @type binary_t_medium :: <<_::16>>
  @type binary_t_large :: <<_::32>>
  @type binary_t :: binary_t_small | binary_t_medium | binary_t_large

  # TODO: if more: false, a size_exponent of 0 should be ignored?
  # otherwise size_exponent of 0 results in size: 16

  @doc """
  Build a Block struct
  If given a Block struct, return it.  If given a message option tuple, build a Block struct.
  """
  @spec build(t()) :: t()
  def build(%__MODULE__{} = block), do: block

  @spec build(tuple_t()) :: t()
  def build({number, more, size}) do
    %__MODULE__{number: number, more: more, size: size}
  end

  @spec build(nil) :: nil
  def build(nil), do: nil

  @spec to_tuple(nil) :: nil
  def to_tuple(nil), do: nil

  @doc """
  Return a block tuple for a block struct.  Return a block tuple when given a block tuple
  """
  @spec to_tuple(t()) :: tuple_t()
  def to_tuple(%__MODULE__{} = block), do: {block.number, block.more, block.size}

  @spec to_tuple(tuple_t()) :: tuple_t()
  def to_tuple(block) when is_tuple(block), do: block

  @doc """
  Decode binary block option to tuple
    small size(4) block number
    medium size(12) block number
    large size(28) block number

  Decode tuple from binary block to Block struct
  """
  @spec decode(binary_t_small()) :: t()
  def decode(<<number::size(4), more::size(1), size_exponent::size(3)>>),
    do: decode(number, more, size_exponent)

  @spec decode(binary_t_medium()) :: t()
  def decode(<<number::size(12), more::size(1), size_exponent::size(3)>>),
    do: decode(number, more, size_exponent)

  @spec decode(binary_t_large()) :: t()
  def decode(<<number::size(28), more::size(1), size_exponent::size(3)>>),
    do: decode(number, more, size_exponent)

  @spec decode(integer, 0 | 1, integer) :: t()
  def decode(number, more, size_exponent) do
    %__MODULE__{
      number: number,
      more: if(more == 0, do: false, else: true),
      size: trunc(:math.pow(2, size_exponent + 4))
    }
  end

  @spec encode(t() | tuple_t()) :: binary_t()
  def encode(%__MODULE__{} = block), do: encode({block.number, block.more, block.size})
  @spec encode(%{number: integer, more: 0 | 1, size: integer}) :: binary_t()
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
