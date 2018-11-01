defmodule CoAP.Payload do
  defstruct segments: [], multipart: false

  def add(nil, segment) do
    %__MODULE__{
      multipart: false,
      segments: [segment]
    }
  end

  def add(%__MODULE__{segments: segments}, segment) do
    %__MODULE__{
      multipart: true,
      segments: [segment | segments]
    }
  end

  def to_binary(%__MODULE__{segments: segments}) do
    segments
    |> Enum.reverse()
    |> Enum.join(<<>>)
  end
end
