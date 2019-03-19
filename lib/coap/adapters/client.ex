defmodule CoAP.Adapters.Client do
  def response(message, {client, peer}, _connection) do
    send(client, {:deliver, message, peer})
  end

  def ack({client, _}) do
    send(client, :ack)
  end
end
