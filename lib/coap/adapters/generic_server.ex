defmodule CoAP.Adapters.GenericServer do
  def request(message, {endpoint, _peer}, owner) do
    message
    |> endpoint.request
    |> deliver(owner)
  end

  defp deliver(result, owner), do: send(owner, {:deliver, result})
end
