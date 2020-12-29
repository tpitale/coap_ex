defmodule CoAP.Message do
  @version 1

  alias CoAP.Multipart

  # import Logger, only: [debug: 1]

  # @max_block_size 1024

  defstruct version: @version,
            type: :con,
            request: nil,
            code_class: 0,
            code_detail: 0,
            method: nil,
            status: nil,
            message_id: 1,
            token: <<0x01>>,
            options: %{},
            multipart: nil,
            payload: <<>>,
            raw_size: 0

  @payload_marker 0xFF

  @methods %{
    # RFC 7252
    # atom indicate a request
    {0, 01} => :get,
    {0, 02} => :post,
    {0, 03} => :put,
    {0, 04} => :delete,
    # success is a tuple {ok, ...}
    {2, 01} => {:ok, :created},
    {2, 02} => {:ok, :deleted},
    {2, 03} => {:ok, :valid},
    {2, 04} => {:ok, :changed},
    {2, 05} => {:ok, :content},
    # block
    {2, 31} => {:ok, :continue},
    # error is a tuple {error, ...}
    {4, 00} => {:error, :bad_request},
    {4, 01} => {:error, :unauthorized},
    {4, 02} => {:error, :bad_option},
    {4, 03} => {:error, :forbidden},
    {4, 04} => {:error, :not_found},
    {4, 05} => {:error, :method_not_allowed},
    {4, 06} => {:error, :not_acceptable},
    # block
    {4, 08} => {:error, :request_entity_incomplete},
    {4, 12} => {:error, :precondition_failed},
    {4, 13} => {:error, :request_entity_too_large},
    {4, 15} => {:error, :unsupported_content_format},
    {5, 00} => {:error, :internal_server_error},
    {5, 01} => {:error, :not_implemented},
    {5, 02} => {:error, :bad_gateway},
    {5, 03} => {:error, :service_unavailable},
    {5, 04} => {:error, :gateway_timeout},
    {5, 05} => {:error, :proxying_not_supported}
  }
  @methods_map Enum.into(@methods, %{}, fn {k, v} -> {v, k} end)

  @type id :: integer()
  @type request_method :: :get | :post | :put | :delete
  @type status_code :: {integer, integer}
  @type status_t :: nil | {atom, atom}

  @type request_type :: :con | :non | :ack | :reset

  @type t :: %__MODULE__{
          version: integer,
          type: request_type,
          request: boolean | nil,
          code_class: integer,
          code_detail: integer,
          method: request_method | nil | {integer, integer},
          status: status_t,
          message_id: id,
          token: binary,
          options: map,
          multipart: CoAP.Multipart.t() | nil,
          payload: binary,
          raw_size: integer
        }

  @types %{
    0 => :con,
    1 => :non,
    2 => :ack,
    3 => :reset
  }
  @types_map Enum.into(@types, %{}, fn {k, v} -> {v, k} end)

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

  @doc """
  Encode a Message struct as binary coap

  Examples

      iex> message = %CoAP.Message{
      iex>   version: 1,
      iex>   type: :con,
      iex>   code_class: 0,
      iex>   code_detail: 3,
      iex>   message_id: 12796,
      iex>   token: <<123, 92, 211, 222>>,
      iex>   options: %{
      iex>     uri_path: ["resource"],
      iex>     uri_query: ["who=world"]
      iex>   },
      iex>   payload: "payload",
      iex>   method: :put,
      iex>   request: true
      iex> }
      iex> CoAP.Message.encode(message)
      <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
  """
  @spec encode(t()) :: binary
  def encode(%__MODULE__{multipart: %Multipart{}} = message) do
    # Always check code_detail in case the message was made directly, not decoded
    blocks = Multipart.as_blocks(request?(message.code_class), message.multipart)

    %__MODULE__{message | options: Map.merge(message.options, blocks), multipart: nil}
    |> encode()
  end

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

    # ensure at least an empty binary
    payload = payload || <<>>

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

  @doc """
  Decode binary coap message into a struct

  Examples:

      iex> message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
      iex> CoAP.Message.decode(message)
      %CoAP.Message{
        version: 1,
        type: :con,
        request: true,
        code_class: 0,
        code_detail: 3,
        message_id: 12796,
        token: <<123, 92, 211, 222>>,
        options: %{
          uri_path: ["resource"],
          uri_query: ["who=world"]
        },
        payload: "payload",
        multipart: %CoAP.Multipart{control: nil, description: nil, more: false, multipart: false, number: 0},
        method: :put,
        raw_size: 35
      }

      iex> message = <<68, 1, 0, 1, 163, 249, 107, 129, 57, 108, 111, 99, 97, 108, 104, 111, 115,
      iex>              116, 131, 97, 112, 105, 0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108,
      iex>              100, 255, 100, 97, 116, 97>>
      iex> CoAP.Message.decode(message)
      %CoAP.Message{
        version: 1,
        type: :con,
        request: true,
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
        multipart: %CoAP.Multipart{control: nil, description: nil, more: false, multipart: false, number: 0},
        method: :get,
        raw_size: 40
      }

      iex> data = <<0x40, 0x01, 0x21, 0x27, 0xB3, 0x61, 0x70, 0x69, 0xC1, 0x15, 0xFF, 0x32, 0x24, 0x0A, 0x0C, 0x0A, 0x0A, 0x33, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31, 0x36, 0x34, 0x12, 0x14, 0x30, 0x31, 0x30, 0x39, 0x32, 0x34, 0x35, 0x30, 0x46, 0x30, 0x41, 0x46, 0x6D, 0x63, 0x75, 0x2D, 0x65, 0x76, 0x74, 0x32>>
      iex> message = CoAP.Message.decode(data)
      iex> message.multipart
      %CoAP.Multipart{
        description: nil,
        control: %CoAP.Block{more: false, number: 1, size: 512},
        multipart: true,
        requested_number: 1,
        requested_size: 512
      }
  """
  @spec decode(binary) :: t()
  def decode(unquote(@message_header_format) = raw_data) do
    <<
      token::binary-size(token_length),
      options_payload::binary
    >> = token_options_payload

    {options, payload} = CoAP.MessageOptions.decode(options_payload)

    request = request?(code_class)

    %__MODULE__{
      version: version,
      type: decode_type(type),
      request: request,
      method: method_for(code_class, code_detail),
      status: status_for(code_class, code_detail),
      code_class: code_class,
      code_detail: code_detail,
      message_id: message_id,
      token: token,
      options: options,
      multipart: multipart(request, options),
      payload: payload,
      raw_size: byte_size(raw_data)
    }
  end

  @doc """
  Encode a response status, e.g., 201 as a message tuple {2, 01}

  Examples

      iex> CoAP.Message.encode_status(201)
      {2, 01}

      iex> CoAP.Message.encode_status(412)
      {4, 12}

  """
  @spec encode_status(integer) :: {integer, integer}
  def encode_status(status) when is_integer(status) do
    [code_class | code_detail] = Integer.digits(status)

    {code_class, code_detail |> Integer.undigits()}
  end

  @doc """
  Encode the request method (get/post/put/delete) for binary message use

  Examples

      iex> CoAP.Message.encode_method(:get)
      {0, 01}

      iex> CoAP.Message.encode_method(:post)
      {0, 02}

      iex> CoAP.Message.encode_method({:ok, :continue})
      {2, 31}

  """
  @spec encode_method(request_method() | status_t()) :: {integer, integer}
  def encode_method(method), do: @methods_map[method]

  @doc """
  Does this message contain a block1 or block2 option

  Examples

      iex> CoAP.Message.multipart(true, %{block1: {1, true, 1024}, block2: {0, false, 512}})
      %CoAP.Multipart{
        control: %CoAP.Block{number: 0, more: false, size: 512},
        description: %CoAP.Block{number: 1, more: true, size: 1024},
        multipart: true,
        more: true,
        number: 1,
        size: 1024,
        requested_size: 512
      }

      iex> CoAP.Message.multipart(true, %{})
      %CoAP.Multipart{multipart: false}

  """
  # _TODO: test if either block1 or block2 is nil
  @spec multipart(boolean, %{block1: CoAP.Block.tuple_t(), block2: CoAP.Block.tuple_t()}) ::
          CoAP.Multipart.t()
  def multipart(request, options) do
    Multipart.build(request, options[:block1], options[:block2])
  end

  @doc """
  Update a Message with the next_message_id
  Ignore fields that should not be carried forward

  Examples

      iex> %CoAP.Message{
      iex>   type: :con,
      iex>   code_class: 0,
      iex>   code_detail: 1,
      iex>   token: <<0x01, 0x02, 0x03, 0x04>>,
      iex>   message_id: 8,
      iex>   method: :get,
      iex>   options: %{},
      iex>   request: true,
      iex>   multipart: %CoAP.Multipart{},
      iex>   payload: "somebigpayload"
      iex> } |> CoAP.Message.next_message(10)
      %CoAP.Message{
        type: :con,
        code_class: 0,
        code_detail: 1,
        token: <<0x01, 0x02, 0x03, 0x04>>,
        message_id: 10,
        method: :get,
        options: %{},
        request: true
      }

  """
  @spec next_message(t(), integer) :: t()
  def next_message(%__MODULE__{} = message, next_message_id) do
    %__MODULE__{message | message_id: next_message_id, payload: <<>>, multipart: nil}
  end

  @doc """
  Create the basic response for a message
  """
  @spec response_for(t()) :: t()
  def response_for(%__MODULE__{type: :con} = message) do
    %__MODULE__{
      type: :ack,
      message_id: message.message_id,
      token: message.token
    }
  end

  def response_for(%__MODULE__{type: :non} = message) do
    %__MODULE__{
      type: :non,
      token: message.token
    }
  end

  @doc """
  Create the response for a message, with a specific method

  Examples

      iex> message = %CoAP.Message{
      iex>   type: :con,
      iex>   message_id: 3,
      iex>   token: <<0x01, 0x02, 0x03, 0x04>>
      iex> }
      iex> CoAP.Message.response_for({:ok, :continue}, message)
      %CoAP.Message{
        type: :ack,
        message_id: 3,
        token: <<0x01, 0x02, 0x03, 0x04>>,
        code_class: 2,
        code_detail: 31
      }

  """
  @spec response_for(request_method() | status_t(), t()) :: t()
  def response_for(method, message) do
    {code_class, code_detail} = encode_method(method)

    %__MODULE__{response_for(message) | code_class: code_class, code_detail: code_detail}
  end

  @doc """
  Create response including status and payload
  """
  @spec response_for(status_code, binary, t()) :: t()
  def response_for({code_class, code_detail}, payload, message) do
    %__MODULE__{
      response_for(message)
      | code_class: code_class,
        code_detail: code_detail,
        payload: payload
    }
  end

  @spec response_for(request_method(), binary, t()) :: t()
  def response_for(method, payload, message) do
    %__MODULE__{response_for(message) | method: method, payload: payload}
  end

  ###
  ### Priv
  ###
  # Encode a request type (con/non/ack/reset) for binary message use
  @spec encode_type(request_type()) :: integer
  defp encode_type(type) when is_atom(type), do: @types_map[type]

  # Decode a binary message into its request type (con/non/ack/reset)
  @spec decode_type(integer) :: request_type()
  defp decode_type(type) when is_integer(type), do: @types[type]

  @spec request?(any) :: boolean
  defp request?(0), do: true

  defp request?(_), do: false

  @spec method_for(any, any) :: request_method() | nil
  defp method_for(0, code_detail), do: @methods[{0, code_detail}]

  defp method_for(_code_class, _code_detail), do: nil

  @spec status_for(integer, any) :: nil | status_t
  defp status_for(0, _code_detail), do: nil

  defp status_for(code_class, code_detail), do: @methods[{code_class, code_detail}]
end
