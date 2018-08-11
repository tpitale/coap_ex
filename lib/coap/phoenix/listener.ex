defmodule CoAP.Phoenix.Listener do
  use GenServer

  import Logger, only: [info: 1]

  def start_link(endpoint, config) do
    info("Starting Listener: #{inspect(config)}")
    GenServer.start_link(__MODULE__, [endpoint, config])
  end

  # TODO: spec for this
  def init([endpoint, config] = _opts) do
    # otp_app = Module.get_attribute(endpoint, :otp_app)
    # config = Phoenix.Endpoint.Supervisor.config(otp_app, endpoint)
    # IO.inspect(config)

    # TODO: fetch info to start coap udp from config
    # TODO: build state from coap udp socket, start listening, ALA listener in
    {:ok, _socket} = :gen_udp.open(config[:local_port], [:binary])

    {:ok, %{endpoint: endpoint, config: config}}
  end

  # TODO: start gen_udp and implement coap protocol
  def handle_info({:udp, socket, address, port, data}, %{endpoint: endpoint, config: config}) do
    # TODO: instrumentation
    info("Received request from #{inspect(address)}:#{inspect(port)}. #{inspect(data)}")

    # TODO: split each of these into its own process, supervise?

    data
    |> CoAP.Message.decode
    |> CoAP.Phoenix.Request.build(socket, address, port)
    |> CoAP.Phoenix.Handler.init({endpoint, config})

    # TODO: ack immediately on con, then send a con later with the same message_id and token?
  end
end
