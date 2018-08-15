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

## Configuration

In phoenix `mix.exs`:

```
config :my_app, MyApp.Coap.Endpoint,
  http: false, https: false, server: false,
  coap: [port: 5683]

```

In `lib/my_app.ex` add supervisor for the endpoint:

```
MyApp.Coap.Endpoint,
{CoAP.Phoenix.Listener, [MyApp.Coap.Endpoint]}
```

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

# TODO:

* [ ] handle multiple parts for some headers, like "Uri-Path"
* [ ] instrumentation of listener/adapter/handler in some way, using phx tools
* [ ] support coaps scheme
* [ ] coap client, ala httpoison

`./coap-client.sh -m put coap://127.0.0.1/resource -e data`
`nc -l 5683 -u | xxd`

```
message = <<0x44, 0x03, 0x31, 0xfc, 0x7b, 0x5c, 0xd3, 0xde, 0xb8, 0x72, 0x65, 0x73, 0x6f, 0x75, 0x72, 0x63, 0x65, 0x49, 0x77, 0x68, 0x6f, 0x3d, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0xff, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64>>
CoAP.Message.decode(message)
```

`coap_content(payload: "data")` comes from using defrecord from gen_coap, right now.

`:coap_client.request(:get, 'coap://127.0.0.1:5683/api/?who=world', coap_content(payload: "payload"), [{:uri_host, "localhost"}])`
