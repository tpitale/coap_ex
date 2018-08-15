defmodule CoaP.MessageOption do
  @payload_marker 0xFF

  # +--------+------------------+-----------+
  # | Number | Name             | Reference |
  # +--------+------------------+-----------+
  # |      0 | (Reserved)       | [RFC7252] |
  # |      1 | If-Match         | [RFC7252] |
  # |      3 | Uri-Host         | [RFC7252] |
  # |      4 | ETag             | [RFC7252] |
  # |      5 | If-None-Match    | [RFC7252] |
  # |      7 | Uri-Port         | [RFC7252] |
  # |      8 | Location-Path    | [RFC7252] |
  # |     11 | Uri-Path         | [RFC7252] |
  # |     12 | Content-Format   | [RFC7252] |
  # |     14 | Max-Age          | [RFC7252] |
  # |     15 | Uri-Query        | [RFC7252] |
  # |     17 | Accept           | [RFC7252] |
  # |     20 | Location-Query   | [RFC7252] |
  # |     35 | Proxy-Uri        | [RFC7252] |
  # |     39 | Proxy-Scheme     | [RFC7252] |
  # |     60 | Size1            | [RFC7252] |
  # |    128 | (Reserved)       | [RFC7252] |
  # |    132 | (Reserved)       | [RFC7252] |
  # |    136 | (Reserved)       | [RFC7252] |
  # |    140 | (Reserved)       | [RFC7252] |
  # +--------+------------------+-----------+
  @options %{
    1 => "If-Match",
    3 => "Uri-Host",
    4 => "ETag",
    5 => "If-None-Match",
    7 => "Uri-Port",
    8 => "Location-Path",
    11 => "Uri-Path",
    12 => "Content-Format",
    14 => "Max-Age",
    15 => "Uri-Query",
    17 => "Accept",
    20 => "Location-Query",
    35 => "Proxy-Uri",
    39 => "Proxy-Scheme",
    60 => "Size1"
  }

  # @options %{
  #   1 => :if_match,
  #   3 => :uri_host,
  #   4 => :etag,
  #   5 => :if_none_match,
  #   7 => :uri_port,
  #   8 => :location_path,
  #   11 => :uri_path,
  #   12 => :content_format,
  #   14 => :max_age,
  #   15 => :uri_query,
  #   17 => :accept,
  #   20 => :location_query,
  #   35 => :proxy_uri,
  #   39 => :proxy_scheme,
  #   60 => :size
  # }

  @option_map %{
    if_match: 1,
    uri_host: 3,
    etag: 4,
    if_none_match: 5,
    uri_port: 7,
    location_path: 8,
    uri_path: 11,
    content_format: 12,
    max_age: 14,
    uri_query: 15,
    accept: 17,
    location_query: 20,
    proxy_uri: 35,
    proxy_scheme: 39,
    size: 60
  }

  @repeatable [
    :if_match,
    :etag,
    :location_path,
    :uri_path,
    :uri_query,
    :location_query
  ]

  defp option_id(option_name) do
    {id, ^option_name} =
      @options
      |> Enum.find(fn {_key, val} -> val == option_name end)

    id
  end

  @types %{
    0 => :con,
    1 => :non,
    2 => :ack,
    3 => :reset,
    con: 0,
    non: 1,
    ack: 2,
    reset: 3
  }

  def decode_type(type_id), do: @types[type_id]
  def encode_type(type), do: @types[type]

  def encode(%{} = options) do
    # {encoded_options, _acc} =
    #   options
    #   |> Map.keys()
    #   |> Enum.map_reduce(0, fn key, delta_sum ->
    #     encode_option(key, options[key], delta_sum)
    #   end)
    #
    # Enum.join(encoded_options)

    options
    |> Map.to_list
    |> encode_options([])
    |> Enum.join
  end

  def encode_options([{_key, nil} | options], acc), do: encode_options(options, acc)
  def encode_options([{key, value} | options], acc) do
    encode_options(options, [encode_option({key, value}, repeatable?(key)) | acc])
  end

  defp repeatable?(key) when key in @repeatable, do: true
  defp repeatable?(_key), do: false

  def encode_option({key, value}, true) do
    # TODO: split, then encode
  end

  def encode_option({key, value}, false) do
  end

  def decode(options_binary) do
    decode(options_binary, %{}, 0)
  end

  defp encode_extended(value) do
    case value do
      v when v in 0..12 -> {v, <<>>}
      v when v in 13..269 -> {13, <<value - 13::unsigned-integer-size(8)>>}
      _ -> {14, <<value - 269::unsigned-integer-size(16)>>}
    end
  end

  defp encode_option(key, value, prev_delta_sum) do
    {delta, delta_extended} = encode_extended(prev_delta_sum + option_id(key))
    {length, length_extended} = encode_extended(byte_size(value))

    result = <<
      delta::unsigned-integer-size(4),
      length::unsigned-integer-size(4),
      delta_extended::binary,
      length_extended::binary,
      value::binary
    >>

    {result, delta}
  end

  # no options or payload present
  defp decode(<<>>, options_acc, options_delta_sum) do
    {options_acc, <<>>, options_delta_sum}
  end

  # no options, just payload
  defp decode(<<@payload_marker, payload::binary>>, options_acc, options_delta_sum) do
    {options_acc, payload, options_delta_sum}
  end

  defp decode(options_binary, options_acc, options_delta_sum) do
    {new_delta_sum, option_name, option_value, options_binary_rest} =
      decode_option(options_binary, options_delta_sum)

    new_acc = Map.put(options_acc, option_name, option_value)

    decode(options_binary_rest, new_acc, new_delta_sum)
  end

  # An 8-bit unsigned integer follows the initial byte and indicates the
  # Option Delta minus 13
  defp decode_option(
         <<13::unsigned-integer-size(4), option_length::unsigned-integer-size(4),
           option_delta_ext::unsigned-integer-size(8), rest::binary>>,
         delta_sum
       ) do
    option_number = delta_sum + (option_delta_ext + 13)
    option_name = @options[option_number]

    {option_value, options_binary_rest} = decode_value(1, option_length, rest)
    {option_number, option_name, option_value, options_binary_rest}
  end

  # A 16-bit unsigned integer in network byte order follows the initial byte
  # and indicates the Option Delta minus 269
  defp decode_option(
         <<14::unsigned-integer-size(4), option_length::unsigned-integer-size(4),
           option_delta_ext::unsigned-integer-size(16), rest::binary>>,
         delta_sum
       ) do
    option_number = delta_sum + (option_delta_ext + 269)
    option_name = @options[option_number]

    {option_value, options_binary_rest} = decode_value(2, option_length, rest)
    {option_number, option_name, option_value, options_binary_rest}
  end

  # Option delta 0-12
  defp decode_option(
         <<option_delta::unsigned-integer-size(4), option_length::unsigned-integer-size(4),
           rest::binary>>,
         delta_sum
       ) do
    option_number = delta_sum + option_delta
    option_name = @options[option_number]

    {option_value, options_binary_rest} = decode_value(0, option_length, rest)
    {option_number, option_name, option_value, options_binary_rest}
  end

  defp decode_value(value_offset, value_length, option_binary_rest) do
    {real_option_length, option_value_rest} =
      case value_length do
        13 ->
          <<_offset::binary-size(value_offset), length_ext::unsigned-integer-size(8),
            option_value_rest::binary>> = option_binary_rest

          {length_ext + 13, option_value_rest}

        14 ->
          <<_offset::binary-size(value_offset), length_ext::unsigned-integer-size(16),
            option_value_rest::binary>> = option_binary_rest

          {length_ext + 269, option_value_rest}

        _ ->
          <<_offset::binary-size(value_offset), option_value_rest::binary>> = option_binary_rest
          {value_length, option_value_rest}
      end

    <<option_value::binary-size(real_option_length), options_binary_rest::binary>> =
      option_value_rest

    {option_value, options_binary_rest}
  end
end
