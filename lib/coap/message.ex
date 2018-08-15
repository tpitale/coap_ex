defmodule CoAP.Message do
  defstruct version: 1,
            type: nil,
            code_class: 0,
            code_detail: 0,
            message_id: 1,
            token: <<0x01>>,
            options: %{},
            payload: <<>>

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
      CoAP.MessageOption.encode(options)::binary,
      @payload_marker,
      payload::binary
    >>
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
        options: %{
          "Uri-Path" => ["resource"],
          "Uri-Query" => ["who=world"]
        },
        payload: "payload"
      }

      iex> message = <<68, 1, 0, 1, 163, 249, 107, 129, 57, 108, 111, 99, 97, 108, 104, 111, 115,
      iex>              116, 131, 97, 112, 105, 0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108,
      iex>              100, 255, 100, 97, 116, 97>>
      iex> CoAP.Message.decode(message)
      %CoAP.Message{
        version: 1,
        type: 0,
        code_class: 0,
        code_detail: 3,
        message_id: 1,
        token: <<123, 92, 211, 222>>,
        options: %{
          "Uri-Path" => ["api", ""],
          "Uri-Query" => ["who=world"],
          "Content-Format" => "text/plain"
          "Uri-Host" => "localhost"
        },
        payload: "data"
      }
  """
  def decode(unquote(@message_header_format)) do
    <<
      token::binary-size(token_length),
      options_payload::binary
    >> = token_options_payload

    {options, payload, _} = CoAP.MessageOption.decode(options_payload)

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
end
