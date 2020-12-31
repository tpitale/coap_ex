# CoAP

Server and Client for building and interacting with Constrained Application Protocol.

Allows using Plug and Phoenix or a standalone module.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `coap` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:coap_ex, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/coap](https://hexdocs.pm/coap).

## Setup

Make a new router and endpoint:

```
defmodule MyApp.Coap.Router do
  use MyApp.Web, :router
end
```

```
defmodule MyApp.Coap.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  plug(MyApp.Coap.Router)
end
```

In phoenix `config.exs`:

```
config :my_app, MyApp.Coap.Endpoint,
  http: false, https: false, server: false,
  coap: [port: 5683]
```

**Note**: if you have control of both client and server, as in an IoT deployment,
you may wish to adjust configuration for `ack_timeout` and `processing_delay`.
This is allowed, but should be used with extreme caution as it exists outside
the boundaries of the CoAP specification.

```
config :my_app, MyApp.Coap.Endpoint,
  http: false, https: false, server: false,
  coap: [port: 5683, ack_timeout: 5000, processing_delay: 4500]
```

In `lib/my_app.ex` add supervisor and listener for the endpoint:

```
children = [
  MyApp.Coap.Endpoint,
  {CoAP.Phoenix.Listener, [MyApp.Coap.Endpoint]}
]
```

# Client #

Simple client usage:

```
CoAP.Client.get("coap://localhost:5683/api/healthcheck")
```

## Options

Client behaviour can be customized through options. See `CoAP.Client`
documentation for possible options.

# Telemetry #

Coap_ex emits telemetry events for data sent and received, block transfers, and other connection-releated events.  To consume them, attach a handler in your app startup like so:

```
:telemetry.attach_many(
  "myapp-coap-ex-connection",
  [
    [:coap_ex, :connection, :block_sent],
    [:coap_ex, :connection, :block_received],
    [:coap_ex, :connection, :connection_started],
    [:coap_ex, :connection, :connection_ended],
    [:coap_ex, :connection, :data_sent],
    [:coap_ex, :connection, :data_received],
    [:coap_ex, :connection, :re_tried],
    [:coap_ex, :connection, :timed_out]
  ],
  &MyHandler.handle_event/4,
  nil
)
```

Each connection can be tagged when the connection is created, and this tag will be passed to the telemetry handler.  This makes it possible to monitor a single connection among many connections. The tag can be any value.

To tag a client connection, pass a tag in the request options:

```
CoAP.Client.request(
  method,
  {url, [], payload},
  %{max_retransmit: retries, timeout: @wait_timeout, tag: tag}
)
 ```
 
 To tag a server connection if using Phoenix:
 
 ```
 # in phoenix controller
 CoAP.Phoenix.Conn.tag(conn, tag)
 ```

# TODO:

* [x] handle multiple parts for some headers, like "Uri-Path"
* [x] coap client, ala httpoison
* [x] message_id is started at a random int and incremented for a single connection
* [x] block-wise transfer
* [ ] handle timeouts and retries of block-wise transfers
* [ ] accept block-wise transfer controls over size
* [ ] respect block-wise transfer controls over size
* [x] respect block-wise transfer controls over block number
* [ ] instrumentation of listener/adapter/handler in some way, using phx tools
* [ ] support coaps scheme
* [x] hostname support?

`./coap-client.sh -m put coap://127.0.0.1/resource -e data`
`nc -l 5683 -u | xxd`

```
message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
CoAP.Message.decode(message)
```

`coap_content(payload: "data")` comes from using defrecord from gen_coap, right now.

`:coap_client.request(:get, 'coap://127.0.0.1:5683/api/?who=world', coap_content(payload: "payload"), [{:uri_host, "localhost"}])`
