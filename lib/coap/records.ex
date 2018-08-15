defmodule CoAP.Records do
  require Record

  Record.defrecord(
    :coap_content,
    Record.extract(
      :coap_content,
      from_lib: "gen_coap/include/coap.hrl"
    )
  )

  Record.defrecord(
    :coap_message,
    Record.extract(
      :coap_message,
      from_lib: "gen_coap/include/coap.hrl"
    )
  )
end
