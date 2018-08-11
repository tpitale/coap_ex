defmodule CoAP.Phoenix.Adapter do
  # TODO: remove once Phoenix allows configuration for schemes beyond http/https
  def child_spec(:http, endpoint, config), do: child_spec(:coap, endpoint, config)
  def child_spec(:coap, endpoint, config) do
    # TODO: pass endpoint and config to listener which starts and gets supervised
    %{
      id: endpoint,
      start: {
        CoAP.Phoenix.Listener,
        :start_link,
        [
          endpoint,
          config
        ]
      },
      restart: :permanent,
      shutdown: :infinity,
      type: :worker,
      modules: [CoAP.Phoenix.Listener]
    }
  end
end
