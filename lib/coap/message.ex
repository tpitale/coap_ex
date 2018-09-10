defmodule CoAP.Message do
  @version 1

  defstruct version: @version,
            type: :con,
            code_class: 0,
            code_detail: 0,
            method: nil,
            message_id: 1,
            token: <<0x01>>,
            options: %{},
            payload: <<>>

  @payload_marker 0xFF

  @methods %{
    # RFC 7252
    # atom indicate a request
    {0,01} => :get,
    {0,02} => :post,
    {0,03} => :put,
    {0,04} => :delete,
    # success is a tuple {ok, ...}
    {2,01} => {:ok, :created},
    {2,02} => {:ok, :deleted},
    {2,03} => {:ok, :valid},
    {2,04} => {:ok, :changed},
    {2,05} => {:ok, :content},
    {2,31} => {:ok, :continue}, # block
    # error is a tuple {error, ...}
    {4,00} => {:error, :bad_request},
    {4,01} => {:error, :unauthorized},
    {4,02} => {:error, :bad_option},
    {4,03} => {:error, :forbidden},
    {4,04} => {:error, :not_found},
    {4,05} => {:error, :method_not_allowed},
    {4,06} => {:error, :not_acceptable},
    {4,08} => {:error, :request_entity_incomplete}, # block
    {4,12} => {:error, :precondition_failed},
    {4,13} => {:error, :request_entity_too_large},
    {4,15} => {:error, :unsupported_content_format},
    {5,00} => {:error, :internal_server_error},
    {5,01} => {:error, :not_implemented},
    {5,02} => {:error, :bad_gateway},
    {5,03} => {:error, :service_unavailable},
    {5,04} => {:error, :gateway_timeout},
    {5,05} => {:error, :proxying_not_supported}
  }
  # @methods_map Enum.into(@methods, %{}, fn {k,v} -> {v,k} end)

  @types %{
    0 => :con,
    1 => :non,
    2 => :ack,
    3 => :reset
  }
  @types_map Enum.into(@types, %{}, fn {k,v} -> {v,k} end)

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
        # TODO: what if payload is <<>>/nil?
        payload: payload,
        options: options
      }) do
    token_length = byte_size(token)

    <<
      version::unsigned-integer-size(2),
      encode_type(type)::unsigned-integer-size(2),
      token_length::unsigned-integer-size(4),
      code_class::unsigned-integer-size(3),
      code_detail::unsigned-integer-size(5),
      message_id::unsigned-integer-size(16),
      token::binary,
      CoAP.MessageOptions.encode(options)::binary,
      @payload_marker,
      payload::binary
    >>
  end

  defp encode_type(type) when is_atom(type), do: @types_map[type]
  defp decode_type(type) when is_integer(type), do: @types[type]

  @doc """
  Decode binary coap message into a struct

  Examples:

      iex> message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
      iex> CoAP.Message.decode(message)
      %CoAP.Message{
        version: 1,
        type: :con,
        code_class: 0,
        code_detail: 3,
        message_id: 12796,
        token: <<123, 92, 211, 222>>,
        options: %{
          uri_path: ["resource"],
          uri_query: ["who=world"]
        },
        payload: "payload",
        method: :put
      }

      iex> message = <<68, 1, 0, 1, 163, 249, 107, 129, 57, 108, 111, 99, 97, 108, 104, 111, 115,
      iex>              116, 131, 97, 112, 105, 0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108,
      iex>              100, 255, 100, 97, 116, 97>>
      iex> CoAP.Message.decode(message)
      %CoAP.Message{
        version: 1,
        type: :con,
        code_class: 0,
        code_detail: 1,
        message_id: 1,
        token: <<163, 249, 107, 129>>,
        options: %{
           uri_path: ["api", ""],
           uri_query: ["who=world"],
           content_format: "text/plain",
           uri_host: "localhost"
        },
        payload: "data",
        method: :get
      }
  """
  def decode(unquote(@message_header_format)) do
    <<
      token::binary-size(token_length),
      options_payload::binary
    >> = token_options_payload

    {options, payload} = CoAP.MessageOptions.decode(options_payload)

    %__MODULE__{
      version: version,
      type: decode_type(type),
      method: method_for(code_class, code_detail),
      code_class: code_class,
      code_detail: code_detail,
      message_id: message_id,
      token: token,
      options: options,
      payload: payload
    }
  end

  defp method_for(0, code_detail), do: @methods[{0, code_detail}]
  defp method_for(_code_class, _code_detail), do: nil

  def response_for(%__MODULE__{type: :con} = message) do
    %__MODULE__{
      type: :con,
      message_id: message.message_id,
      token: message.token
    }
  end
end
