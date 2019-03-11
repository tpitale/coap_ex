defmodule CoAP.MessageOption do
  # @payload_marker 0xFF

  defmodule UnsignedOptions do
    defmacro __using__(_) do
      quote do
        @unsigned [
          :uri_port,
          :max_age,
          :accept,
          :size1,
          :observe,
          :content_format
        ]
      end
    end
  end

  @repeatable_options [
    :if_match,
    :etag,
    :location_path,
    :uri_path,
    :uri_query,
    :location_query
  ]

  def decode(option_id, value) do
    __MODULE__.Decoder.to_tuple(option_id, value)
  end

  def encode({key, value}) do
    __MODULE__.Encoder.encode({key, value})
  end

  def repeatable?(key) when key in @repeatable_options, do: true
  def repeatable?(_key), do: false

  defmodule Decoder do
    @options %{
      1 => :if_match,
      3 => :uri_host,
      4 => :etag,
      5 => :if_none_match,
      # draft-ietf-core-observe-16
      6 => :observe,
      7 => :uri_port,
      8 => :location_path,
      11 => :uri_path,
      12 => :content_format,
      14 => :max_age,
      15 => :uri_query,
      17 => :accept,
      20 => :location_query,
      # draft-ietf-core-block-17
      23 => :block2,
      27 => :block1,
      35 => :proxy_uri,
      39 => :proxy_scheme,
      60 => :size1
    }

    @content_formats %{
      0 => "text/plain",
      40 => "application/link-format",
      41 => "application/xml",
      42 => "application/octet-stream",
      47 => "application/exi",
      50 => "application/json",
      60 => "application/cbor"
    }

    use CoAP.MessageOption.UnsignedOptions

    def to_tuple(option_id, value) do
      decode_option(option_id, value)
    end

    defp decode_option(option_id, value) when is_integer(option_id) do
      decode_option(@options[option_id], value)
    end

    defp decode_option(key, value) when is_atom(key), do: {key, decode_value(key, value)}

    defp decode_value(:if_none_match, <<>>), do: true
    defp decode_value(:block1, value), do: CoAP.Block.decode(value)
    defp decode_value(:block2, value), do: CoAP.Block.decode(value)

    defp decode_value(:content_format, value) do
      content_id = :binary.decode_unsigned(value)
      @content_formats[content_id] || content_id
    end

    defp decode_value(key, value) when key in @unsigned, do: :binary.decode_unsigned(value)
    defp decode_value(_key, value), do: value
  end

  defmodule Encoder do
    @options %{
      if_match: 1,
      uri_host: 3,
      etag: 4,
      if_none_match: 5,
      # draft-ietf-core-observe-16
      observe: 6,
      uri_port: 7,
      location_path: 8,
      uri_path: 11,
      content_format: 12,
      max_age: 14,
      uri_query: 15,
      accept: 17,
      location_query: 20,
      # draft-ietf-core-block-17
      block2: 23,
      block1: 27,
      proxy_uri: 35,
      proxy_scheme: 39,
      size1: 60
    }

    @content_formats %{
      "text/plain" => 0,
      "application/link-format" => 40,
      "application/xml" => 41,
      "application/octet-stream" => 42,
      "application/exi" => 47,
      "application/json" => 50,
      "application/cbor" => 60
    }

    use CoAP.MessageOption.UnsignedOptions

    def encode({key, value}) do
      encode({key, value}, CoAP.MessageOption.repeatable?(key))
    end

    def encode({key, value}, false), do: encode_option({key, value})

    def encode({key, values}, true) do
      # we must keep the order
      values
      # remove nil
      |> Enum.filter(fn v -> v end)
      |> Enum.map(&encode_option({key, &1}))
    end

    # Encode special cases
    defp encode_option({:block2, value}), do: {@options[:block2], CoAP.Block.encode(value)}
    defp encode_option({:block1, value}), do: {@options[:block1], CoAP.Block.encode(value)}
    defp encode_option({:if_none_match, true}), do: {@options[:if_none_match], <<>>}

    defp encode_option({:content_format, value}) when is_binary(value) do
      {:content_format, @content_formats[value]}
      |> encode_option
    end

    # Encode unsigned integer values
    defp encode_option({key, value}) when key in @unsigned do
      {@options[key], :binary.encode_unsigned(value)}
    end

    # Encode everything else
    # binary
    defp encode_option({key, value}) when is_atom(key), do: {@options[key], value}
    defp encode_option({key, value}) when is_integer(key), do: {key, value}
  end
end
