defmodule CoAP.Phoenix.Listener do
  @moduledoc """
    CoAP.Phoenix.Listner looks up Phoenix config and
    starts a SocketServer on the configured port to wrap the endpoint (Phoenix router)
  """
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

    {:ok, server} = CoAP.SocketServer.start_link([{@adapter, endpoint}, config[:port], config])
    # TODO: ref and monitor?
    # TODO: die if server dies?

    {:ok, %{endpoint: endpoint, config: config, server: server}}
  end
end
