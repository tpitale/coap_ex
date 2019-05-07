defmodule CoAP.Adapters.Client do
  def response(message, {client, peer}, _connection) do
    send(client, {:deliver, message, peer})
  end

  def error({client, %{reason: reason}}) do
    send(client, {:error, reason})
  end
end
