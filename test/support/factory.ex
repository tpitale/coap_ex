defmodule CoAP.Test.Support.Factory do
  @moduledoc false

  import ExUnitProperties
  import StreamData

  alias CoAP.Block
  alias CoAP.Message
  alias CoAP.Multipart

  @doc false
  def message do
    gen all(
          type <- member_of([:con, :non, :ack, :reset]),
          request <- one_of([boolean(), constant(nil)]),
          code_class <- integer(0..7),
          code_detail <- integer(0..31),
          method <-
            one_of([
              member_of([:get, :post, :put, :delete]),
              constant(nil),
              tuple({integer(0..7), integer(0..31)})
            ]),
          status <-
            one_of([
              constant(nil),
              tuple({atom(:alphanumeric), atom(:alphanumeric)})
            ]),
          message_id <- integer(0..65_535),
          token <- binary(min_length: 0, max_length: 64),
          options <- options(),
          multipart <- one_of([multipart(), constant(nil)]),
          payload <- binary(min_length: 0, max_length: 65_535)
        ) do
      %Message{
        version: 1,
        type: type,
        request: request,
        code_class: code_class,
        code_detail: code_detail,
        method: method,
        status: status,
        message_id: message_id,
        token: token,
        options: options,
        multipart: multipart,
        payload: payload
      }
    end
  end

  @doc false
  def multipart do
    gen all(
      description <- one_of([block(), constant(nil)]),
      control <- one_of([block(), constant(nil)])
      ) do
      %Multipart{
        multipart: true,
        description: description,
        control: control,
        more: (if description, do: description.more, else: nil),
        number: (if description, do: description.number, else: nil),
        size: (if description, do: description.size, else: nil),
        requested_number: (if control, do: control.number, else: nil),
        requested_size: (if control, do: control.size, else: nil)
      }
    end
  end

  @doc false
  def block do
    gen all(
      number <- integer(0..65_535),
      more <- boolean(),
      size <- integer(0..65_535)
    ) do
      %Block{number: number, more: more, size: size}
    end
  end

  @doc false
  def options do
    gen all(
          options <- map_of(integer(0..65_535), string(:ascii, max_length: 12 * 8), max_length: 16)
        ) do
      options
    end
  end
end
