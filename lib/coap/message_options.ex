defmodule CoAP.MessageOptions do
  @payload_marker 0xFF

  @doc """

  Examples

      iex> message = <<57, 108, 111, 99, 97, 108, 104, 111, 115, 116, 131, 97, 112, 105,
      iex>             0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108, 100>>
      iex> CoAP.MessageOptions.decode(message)
      {%{
        uri_path: ["api", ""],
        uri_query: ["who=world"],
        content_format: "text/plain",
        uri_host: "localhost"
      }, <<>>}
  """
  def decode(message) do
    __MODULE__.Decoder.options_and_payload(message)
  end

  @doc """

  Examples

      iex> options = %{
      iex>   uri_path: ["api", ""],
      iex>   uri_query: ["who=world"],
      iex>   content_format: "text/plain",
      iex>   uri_host: "localhost"
      iex> }
      iex> CoAP.MessageOptions.encode(options)
      <<57, 108, 111, 99, 97, 108, 104, 111, 115, 116, 131, 97, 112, 105,
        0, 17, 0, 57, 119, 104, 111, 61, 119, 111, 114, 108, 100>>
  """
  def encode(options) do
    __MODULE__.Encoder.to_binary(options)
  end

  defmodule Decoder do
    def options_and_payload(options) when is_binary(options) do
      {option_list, payload} = decode(options)
      {option_list |> Enum.into(%{}), payload}
    end

    defp decode(options), do: decode(options, 0, [])
    defp decode(<<>>, _last_num, option_list), do: {option_list, <<>>}
    defp decode(<<0xFF, payload::binary>>, _last_num, option_list), do: {option_list, payload}

    defp decode(<<delta::size(4), length::size(4), tail::binary>>, delta_sum, option_list) do
      {key, length, tail} = decode_extended(delta_sum, delta, length, tail)

      # key becomes the next delta_sum
      case tail do
        <<value::binary-size(length), rest::binary>> ->
          decode(rest, key, append_option(CoAP.MessageOption.decode(key, value), option_list))
        <<>> ->
          decode(<<>>, key, append_option(CoAP.MessageOption.decode(key, <<>>), option_list))
      end
    end

    defp decode_extended(delta_sum, delta, length, tail) do
      {tail1, key} = cond do
        delta < 13 ->
          {tail, delta_sum + delta}
        delta == 13 ->
          # TODO: size here `::size(4)`?
          <<key, new_tail1::binary>> = tail
          {new_tail1, delta_sum + key + 13}
        delta == 14 ->
          <<key::size(16), new_tail1::binary>> = tail
          {new_tail1, delta_sum + key + 269}
        end

      {tail2, option_length} = cond do
        length < 13 ->
          {tail1, length}
        length == 13 ->
          # TODO: size here `::size(4)`?
          <<extended_option_length, new_tail2::binary>> = tail1
          {new_tail2, extended_option_length + 13}
        length == 14 ->
          <<extended_option_length::size(16), new_tail2::binary>> = tail1
          {new_tail2, extended_option_length + 269}
        end

      {key, option_length, tail2}
    end

    # put options of the same id into one list
    # Is this new key already in the list as the previous value?
    defp append_option({key, value}, [{key, values} | options]) do
      case CoAP.MessageOption.repeatable?(key) do
        true ->
          # we must keep the order
          [{key, values++[value]} | options];
        false ->
          throw({:error, "#{key} is not repeatable"})
      end
    end

    defp append_option({key, value}, options) do
      case CoAP.MessageOption.repeatable?(key) do
        true -> [{key, [value]} | options]
        false -> [{key, value} | options]
      end
    end
  end

  defmodule Encoder do
    def to_binary(options) do
      encode(options)
    end

    defp encode(options) when is_map(options) do
      options
      |> Map.to_list
      |> Enum.map(&CoAP.MessageOption.encode/1)
      |> List.flatten
      |> sort
      |> encode(0, <<>>)
    end

    # Take key/value pairs from options and turn them into option_id/binary values list
    # defp encode_options([], acc), do: acc
    # defp encode_options([{_key, nil} | options], acc), do: encode_options(options, acc)
    # defp encode_options([{key, value} | options], acc) do
    #   encode_options(options, [({key, value}) | acc])
    # end

    defp sort(options), do: :lists.keysort(1, options)

    # defp encode_option_list(options, nil), do: encode_option_list(options)
    # defp encode_option_list(options, <<>>), do: encode_option_list(options)
    # defp encode_option_list(options, payload) do
    #   <<encode_option_list(options)::binary, 0xFF, payload::binary>>
    # end

    defp encode([{key, value} | option_list], delta_sum, acc) do
      {delta, extended_number} = cond do
        key - delta_sum >= 269 ->
          {14, <<(key - delta_sum - 269)::size(16)>>}
        key - delta_sum >= 13 ->
          {13, <<(key - delta_sum - 13)>>}
        true ->
          {key - delta_sum, <<>>}
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
        # TODO: what size should this be?
        extended_number::binary,
        extended_length::binary,
        value::binary
      >>
      encode(option_list, key, acc2)
    end

    defp encode([], _delta_sum, acc), do: acc
  end
end
