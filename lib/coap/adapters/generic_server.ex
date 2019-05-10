defmodule CoAP.Adapters.GenericServer do
  def request(message, {endpoint, _peer}, owner) do
    message
    |> endpoint.request
    |> deliver(owner)
  end

  def error({_endpoint, %{reason: {:timeout, _phase}}}), do: nil

  defp deliver(result, owner), do: send(owner, {:deliver, result})
end
