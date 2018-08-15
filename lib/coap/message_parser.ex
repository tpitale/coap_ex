#
# The contents of this file are subject to the Mozilla Public License
# Version 1.1 (the "License") you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
# http://www.mozilla.org/MPL/
#
# Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
#

# encoding and decoding for CoAP v1 messages
defmodule CoAP.MessageParser do

  # -export([decode/1, decode_type/1, encode/1, message_id/1])

  import :core_iana, only: [decode_enum: 2, decode_enum: 3, encode_enum: 2, encode_enum: 3]

  import CoAP.Records

  @version 1

  @option_if_match 1
  @option_uri_host 3
  @option_etag 4
  @option_if_none_match 5
  @option_observe 6 # draft-ietf-core-observe-16
  @option_uri_port 7
  @option_location_path 8
  @option_uri_path 11
  @option_content_format 12
  @option_max_age 14
  @option_uri_query 15
  @option_accept 17
  @option_location_query 20
  @option_block2 23 # draft-ietf-core-block-17
  @option_block1 27
  @option_proxy_uri 35
  @option_proxy_scheme 39
  @option_size1 60

  # empty message only contains the 4-byte header
  def decode(<<@version::size(2), type::size(2), 0::size(4), 0::size(3), 0::size(5), message_id::size(16)>>) do
    coap_message(type: decode_type(type), id: message_id)
  end

  def decode(<<@version::size(2), type::size(2), token_length::size(4), class::size(3), code::size(5), message_id::size(16), token::binary-size(token_length), tail::binary>>) do
    {options, payload} = decode_option_list(tail)
    coap_message(
      type: decode_type(type),
      method: decode_enum(methods(), {class, code}),
      id: message_id,
      token: token,
      options: options,
      payload: payload
    )
  end

  # empty message
  def encode(coap_message(type: type, method: nil, id: message_id)) do
    <<@version::size(2), (encode_type(type))::size(2), 0::size(4), 0::size(3), 0::size(5), message_id::size(16)>>;
  end

  def encode(coap_message(type: type, method: method, id: message_id, token: token, options: options, payload: payload)) do
    token_length = byte_size(token)
    {class, code} = encode_enum(methods(), method)
    tail = encode_option_list(options, payload)
    <<@version::size(2), (encode_type(type))::size(2), token_length::size(4), class::size(3), code::size(5), message_id::size(16), token::binary-size(token_length), tail::binary>>
  end

  # shortcut function for reset generation
  def message_id(<<_unused::size(16), message_id::size(16), _tail::binary>>), do: message_id
  def message_id(coap_message(id: message_id)), do: message_id

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

  def decode_type(type) when is_integer(type), do: @types[type]
  def encode_type(type) when is_atom(type), do: @types[type]

  # def decode_type(0), do: :con
  # def decode_type(1), do: :non
  # def decode_type(2), do: :ack
  # def decode_type(3), do: :reset

  # def encode_type(:con), do: 0
  # def encode_type(:non), do: 1
  # def encode_type(:ack), do: 2
  # def encode_type(:reset), do: 3

  def methods do
    [
      # RFC 7252
      # atom indicate a request
      {{0,01}, :get},
      {{0,02}, :post},
      {{0,03}, :put},
      {{0,04}, :delete},
      # success is a tuple {ok, ...}
      {{2,01}, {:ok, :created}},
      {{2,02}, {:ok, :deleted}},
      {{2,03}, {:ok, :valid}},
      {{2,04}, {:ok, :changed}},
      {{2,05}, {:ok, :content}},
      {{2,31}, {:ok, :continue}}, # block
      # error is a tuple {error, ...}
      {{4,00}, {:error, :bad_request}},
      {{4,01}, {:error, :unauthorized}},
      {{4,02}, {:error, :bad_option}},
      {{4,03}, {:error, :forbidden}},
      {{4,04}, {:error, :not_found}},
      {{4,05}, {:error, :method_not_allowed}},
      {{4,06}, {:error, :not_acceptable}},
      {{4,08}, {:error, :request_entity_incomplete}}, # block
      {{4,12}, {:error, :precondition_failed}},
      {{4,13}, {:error, :request_entity_too_large}},
      {{4,15}, {:error, :unsupported_content_format}},
      {{5,00}, {:error, :internal_server_error}},
      {{5,01}, {:error, :not_implemented}},
      {{5,02}, {:error, :bad_gateway}},
      {{5,03}, {:error, :service_unavailable}},
      {{5,04}, {:error, :gateway_timeout}},
      {{5,05}, {:error, :proxying_not_supported}}
    ]
  end

  # option parsing is based on Patrick's CoAP Message Parsing in Erlang
  # https://gist.github.com/azdle/b2d477ff183b8bbb0aa0

  def decode_option_list(tail), do: decode_option_list(tail, 0, [])
  def decode_option_list(<<>>, _last_num, option_list), do: {option_list, <<>>}
  def decode_option_list(<<0xFF, payload::binary>>, _last_num, option_list), do: {option_list, payload}

  def decode_option_list(<<delta::size(4), length::size(4), tail::binary>>, last_num, option_list) do
    {tail1, key} = cond do
      delta < 13 ->
        {tail, last_num + delta}
      delta == 13 ->
        <<key, new_tail1::binary>> = tail
        {new_tail1, last_num + key + 13}
      delta == 14 ->
        <<key::size(16), new_tail1::binary>> = tail
        {new_tail1, last_num + key + 269}
      end

    {tail2, option_length} = cond do
      length < 13 ->
        {tail1, length}
      length == 13 ->
        <<extended_option_length, new_tail2::binary>> = tail1
        {new_tail2, extended_option_length + 13}
      length == 14 ->
        <<extended_option_length::size(16), new_tail2::binary>> = tail1
        {new_tail2, extended_option_length + 269}
      end

    case tail2 do
      <<value::binary-size(option_length), next_option::binary>> ->
        decode_option_list(next_option, key, append_option(decode_option(key, value), option_list))
      <<>> ->
        decode_option_list(<<>>, key, append_option(decode_option(key, <<>>), option_list))
    end
  end

  # put options of the same id into one list
  def append_option({same_option_id, value2}, [{same_option_id, value1} | options]) do
    case repeatable?(same_option_id) do
      true ->
        # we must keep the order
        [{same_option_id, value1++[value2]} | options];
      false ->
        throw({:error, "#{same_option_id} is not repeatable"})
    end
  end

  def append_option({key, value}, options) do
    case repeatable?(key) do
      true -> [{key, [value]} | options];
      false -> [{key, value} | options]
    end
  end

  def encode_option_list(options, <<>>), do: encode_option_list1(options)
  def encode_option_list(options, payload) do
    <<(encode_option_list1(options))::binary, 0xFF, payload::binary>>
  end

  def encode_option_list1(options) do
    options1 = encode_options(options, [])
    # sort before encoding so we can calculate the deltas
    # the sort is stable; it maintains relative order of values with equal keys
    encode_option_list(:lists.keysort(1, options1), 0, <<>>)
  end

  def encode_options([], acc), do: acc
  def encode_options([{_key, nil} | options], acc), do: encode_options(options, acc)
  def encode_options([{key, value} | options], acc) do
    case repeatable?(key) do
      true ->
        encode_options(options, split_and_encode_option({key, value}, acc))
      false ->
        encode_options(options, [encode_option({key, value}) | acc])
    end
  end

  def split_and_encode_option({_key, []}, acc), do: acc
  def split_and_encode_option({key, [nil | values]}, acc), do: split_and_encode_option({key, values}, acc)
  def split_and_encode_option({key, [value | values]}, acc) do
    # we must keep the order
    [encode_option({key, value}) | split_and_encode_option({key, values}, acc)]
  end


  def encode_option_list([{key, value} | option_list], last_num, acc) do
    {delta, extended_number} = cond do
      key - last_num >= 269 ->
        {14, <<(key - last_num - 269)::size(16)>>}
      key - last_num >= 13 ->
        {13, <<(key - last_num - 13)>>}
      true ->
        {key - last_num, <<>>}
    end

    {length, extended_length} = cond do
      byte_size(value) >= 269 ->
        {14, <<(byte_size(value) - 269)::size(16)>>}
      byte_size(value) >= 13 ->
        {13, <<(byte_size(value) - 13)>>}
      true ->
        {byte_size(value), <<>>}
    end

    acc2 = <<
      acc::binary,
      delta::size(4),
      length::size(4),
      extended_number::binary,
      extended_length::binary,
      value::binary
    >>
    encode_option_list(option_list, key, acc2)
  end

  def encode_option_list([], _last_num, acc), do: acc

  @repeatable [
    :if_match,
    :etag,
    :location_path,
    :uri_path,
    :uri_query,
    :location_query
  ]

  defp repeatable?(key) when key in @repeatable, do: true
  defp repeatable?(_key), do: false

  # RFC 7252
  def decode_option(@option_if_match, value), do: {:if_match, value}
  def decode_option(@option_uri_host, value), do: {:uri_host, value}
  def decode_option(@option_etag, value), do: {:etag, value}
  def decode_option(@option_if_none_match, <<>>), do: {:if_none_match, true}
  def decode_option(@option_uri_port, value), do: {:uri_port, :binary.decode_unsigned(value)}
  def decode_option(@option_location_path, value), do: {:location_path, value}
  def decode_option(@option_uri_path, value), do: {:uri_path, value}
  def decode_option(@option_content_format, value) do
    number = :binary.decode_unsigned(value)
    {:content_format, decode_enum(:core_iana.content_formats(), number, number)}
  end
  def decode_option(@option_max_age, value), do: {:max_age, :binary.decode_unsigned(value)}
  def decode_option(@option_uri_query, value), do: {:uri_query, value}
  def decode_option(@option_accept, value), do: {:accept, :binary.decode_unsigned(value)}
  def decode_option(@option_location_query, value), do: {:location_query, value}
  def decode_option(@option_proxy_uri, value), do: {:proxy_uri, value}
  def decode_option(@option_proxy_scheme, value), do: {:proxy_scheme, value}
  def decode_option(@option_size1, value), do: {:size1, :binary.decode_unsigned(value)}
  # draft-ietf-core-observe-16
  def decode_option(@option_observe, value), do: {:observe, :binary.decode_unsigned(value)}
  # draft-ietf-core-block-17
  def decode_option(@option_block2, value), do: {:block2, decode_block(value)}
  def decode_option(@option_block1, value), do: {:block1, decode_block(value)}
  # unknown option
  def decode_option(key, value), do: {key, value}

  def decode_block(<<number::size(4), more::size(1), extended_size::size(3)>>), do: decode_block(number, more, extended_size)
  def decode_block(<<number::size(12), more::size(1), extended_size::size(3)>>), do: decode_block(number, more, extended_size)
  def decode_block(<<number::size(28), more::size(1), extended_size::size(3)>>), do: decode_block(number, more, extended_size)

  def decode_block(number, more, extended_size) do
    {number, (if more == 0, do: false, else: true), trunc(:math.pow(2, extended_size+4))}
  end


  # RFC 7252
  def encode_option({:if_match, value}), do: {@option_if_match, value}
  def encode_option({:uri_host, value}), do: {@option_uri_host, value}
  def encode_option({:etag, value}), do: {@option_etag, value}
  def encode_option({:if_none_match, true}), do: {@option_if_none_match, <<>>}
  def encode_option({:uri_port, value}), do: {@option_uri_port, :binary.encode_unsigned(value)}
  def encode_option({:location_path, value}), do: {@option_location_path, value}
  def encode_option({:uri_path, value}), do: {@option_uri_path, value}
  def encode_option({:content_format, value}) when is_integer(value) do
    {@option_content_format, :binary.encode_unsigned(value)}
  end
  def encode_option({:content_format, value}) do
    number = encode_enum(:core_iana.content_formats(), value)
    {@option_content_format, :binary.encode_unsigned(number)}
  end
  def encode_option({:max_age, value}), do: {@option_max_age, :binary.encode_unsigned(value)}
  def encode_option({:uri_query, value}), do: {@option_uri_query, value}
  def encode_option({:accept, value}), do: {@option_accept, :binary.encode_unsigned(value)}
  def encode_option({:location_query, value}), do: {@option_location_query, value}
  def encode_option({:proxy_uri, value}), do: {@option_proxy_uri, value}
  def encode_option({:proxy_scheme, value}), do: {@option_proxy_scheme, value}
  def encode_option({:size1, value}), do: {@option_size1, :binary.encode_unsigned(value)}
  # draft-ietf-core-observe-16
  def encode_option({:observe, value}), do: {@option_observe, :binary.encode_unsigned(value)}
  # draft-ietf-core-block-17
  def encode_option({:block2, value}), do: {@option_block2, encode_block(value)}
  def encode_option({:block1, value}), do: {@option_block1, encode_block(value)}
  # unknown option
  def encode_option({key, value}) when is_integer(key), do: {key, value}

  def encode_block({number, more, size}) do
    encode_block(number, (if more, do: 1, else: 0), trunc(log2(size))-4)
  end

  def encode_block(number, more, extended_size) when number < 16 do
    <<number::size(4), more::size(1), extended_size::size(3)>>
  end
  def encode_block(number, more, extended_size) when number < 4096 do
    <<number::size(12), more::size(1), extended_size::size(3)>>
  end
  def encode_block(number, more, extended_size) do
    <<number::size(28), more::size(1), extended_size::size(3)>>
  end

  # log2 is not available in R16B
  def log2(x), do: :math.log(x) / :math.log(2)

  # # -include_lib("eunit/include/eunit.hrl")
  #
  # # note that the options below must be sorted by the option numbers
  # codec_test_()-> [
  #     test_codec(coap_message({type=reset, id=0, options=[]}),
  #     test_codec(coap_message({type=con, method=get, id=100,
  #         options=[{block1, {0,true,128}}, {observe, 1}]}),
  #     test_codec(coap_message({type=non, method=put, id=200, token= <<"token">>,
  #         options=[{uri_path,[<<".well-known">>, <<"core">>]}]}),
  #     test_codec(coap_message({type=non, method={ok, 'content'}, id=300, token= <<"token">>,
  #         payload= <<"<url>">>, options=[{content_format, <<"application/link-format">>}, {uri_path,[<<".well-known">>, <<"core">>]}]})].
  #
  # test_codec(Message) do
  #     Message2 = encode(Message),
  #     Message1 = decode(Message2),
  #     @_assertequal(Message, Message1).

end
