defmodule CoAP.Phoenix.Listener do
  use GenServer

  import Logger, only: [info: 1]

  def child_spec(endpoint) do
    %{
      id: {__MODULE__, endpoint},
      start: {
        __MODULE__,
        :start_link,
        [
          endpoint
        ]
      },
      restart: :permanent,
      shutdown: :infinity,
      type: :worker,
      modules: [__MODULE__]
    }
  end


  def start_link(endpoint) do
    GenServer.start_link(__MODULE__, endpoint)
  end

  # TODO: spec for this
  def init([endpoint]) do
    config = endpoint.config(:coap)

    info("Starting Listener: #{inspect(config)}")

    # TODO: fetch info to start coap udp from config
    # TODO: build state from coap udp socket, start listening, ALA listener in
    {:ok, _socket} = :gen_udp.open(config[:port], [:binary])

    {:ok, %{endpoint: endpoint, config: config}}
  end

  # TODO: start gen_udp and implement coap protocol
  def handle_info({:udp, socket, address, port, data}, %{endpoint: endpoint, config: config}) do
    # TODO: instrumentation
    info("Received request from #{inspect(address)}:#{inspect(port)}. #{inspect(data)}")

    # TODO: split each of these into its own process, supervise?

    data
    |> CoAP.Message.decode
    |> CoAP.Phoenix.Request.build(socket, address, port, config)
    |> CoAP.Phoenix.Handler.init({endpoint, config})

    # TODO: ack immediately on con, then send a con later with the same message_id and token?
  end
end
