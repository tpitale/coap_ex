defmodule CoAP.Adapters.Client do
  def response(message, {client, peer}, _connection) do
    send(client, {:deliver, message, peer})
  end
end
