defmodule CoAP.Message do
  import Logger, only: [info: 1]

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

  # @message_types %{
  #   0 => :con, # Confirmable
  #   1 => :non, # Non-confirmable
  #   2 => :ack, # Acknowledge
  #   3 => :res  # Reset
  # }

  # TODO: move to CoapOptions module
  def option_id(option_name) do
    {id, ^option_name} =
      @options
      |> Enum.find(fn {_key, val} -> val == option_name end)

    id
  end

  @payload_marker 0xFF

  @message_header_format (quote do
                    <<
                      var!(version)::unsigned-integer-size(2),
                      var!(type)::unsigned-integer-size(2),
                      var!(token_length)::unsigned-integer-size(4),
                      var!(code_class)::unsigned-integer-size(3),
                      var!(code_detail)::unsigned-integer-size(5),
                      var!(message_id)::unsigned-integer-size(16),
                      var!(token_options_payload)::binary
                    >>
                  end)

  defstruct version: 1,
            type: nil,
            code_class: 0,
            code_detail: 0,
            message_id: 1,
            token: <<0x01>>,
            options: %{},
            payload: <<>>

  def encode(%__MODULE__{
        version: version,
        type: type,
        code_class: code_class,
        code_detail: code_detail,
        message_id: message_id,
        token: token,
        payload: payload,
        options: options
      }) do
    token_length = byte_size(token)

    <<
      version::unsigned-integer-size(2),
      type::unsigned-integer-size(2),
      token_length::unsigned-integer-size(4),
      code_class::unsigned-integer-size(3),
      code_detail::unsigned-integer-size(5),
      message_id::unsigned-integer-size(16),
      token::binary,
      encode_options(options)::binary,
      @payload_marker,
      payload::binary
    >>
  end

  def encode_options(%{} = options) do
    {encoded_options, _acc} =
      options
      |> Map.keys()
      |> Enum.map_reduce(0, fn key, delta_sum ->
        encode_option(key, options[key], delta_sum)
      end)

    Enum.join(encoded_options)
  end

  def encode_option(key, value, prev_delta_sum) do
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

  defp encode_extended(value) do
    case value do
      v when v in 0..12 -> {v, <<>>}
      v when v in 13..269 -> {13, <<value - 13::unsigned-integer-size(8)>>}
      _ -> {14, <<value - 269::unsigned-integer-size(16)>>}
    end
  end

  @doc """
  Decode binary coap message into a struct

  Examples:

      iex> message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
      iex> CoAP.Message.decode(message)
      %CoAP.Message{
        version: 1,
        type: 0,
        code_class: 0,
        code_detail: 3,
        message_id: 12796,
        token: <<123, 92, 211, 222>>,
        options: %{"Uri-Path" => "resource", "Uri-Query" => "who=world"},
        payload: "payload"
      }
  """
  def decode(unquote(@message_header_format)) do
    <<
      token::binary-size(token_length),
      options_payload::binary
    >> = token_options_payload

    {options, payload, _} = decode_options(options_payload)

    %__MODULE__{
      version: version,
      type: type,
      code_class: code_class,
      code_detail: code_detail,
      message_id: message_id,
      token: token,
      options: options,
      payload: payload
    }
  end

  defp decode_options(options_binary) do
    decode_options(options_binary, %{}, 0)
  end

  # no options or payload present
  defp decode_options(<<>>, options_acc, options_delta_sum) do
    {options_acc, <<>>, options_delta_sum}
  end

  # no options, just payload
  defp decode_options(<<@payload_marker, payload::binary>>, options_acc, options_delta_sum) do
    {options_acc, payload, options_delta_sum}
  end

  defp decode_options(options_binary, options_acc, options_delta_sum) do
    {new_delta_sum, option_name, option_value, options_binary_rest} = decode_option(options_binary, options_delta_sum)

    info("#{inspect({new_delta_sum, option_name, option_value, options_binary_rest})}")

    new_acc = Map.put(options_acc, option_name, option_value)

    decode_options(options_binary_rest, new_acc, new_delta_sum)
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
