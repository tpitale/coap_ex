defmodule CoAP.Phoenix.Listener do
  use GenServer

  @adapter CoAP.Adapters.Phoenix

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
  def init(endpoint) do
    # TODO: take this config and use it to start a CoAP.SocketServer
    config = endpoint.config(:coap)

    info("Starting CoAP.Phoenix.Listener: #{inspect(config)}")

    {:ok, server} = CoAP.SocketServer.start_link([config[:port], {@adapter, endpoint}])
    # TODO: ref and monitor?
    # TODO: die if server dies?

    {:ok, %{endpoint: endpoint, config: config, server: server}}
  end

  # # TODO: start gen_udp and implement coap protocol
  # def handle_info({:udp, socket, address, port, data}, %{endpoint: endpoint, config: config}) do
  #   # TODO: instrumentation
  #   info("Received request from #{inspect(address)}:#{inspect(port)}. #{inspect(data)}")
  #
  #   # TODO: split each of these into its own process, supervise?
  #
  #   data
  #   |> CoAP.Message.decode
  #   |> CoAP.Phoenix.Request.build(socket, address, port, config)
  #   |> CoAP.Phoenix.Handler.init({endpoint, config})
  # end
end
