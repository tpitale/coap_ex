defmodule CoAP.Handler do
  use GenServer

  @moduledoc """
  Thin wrapper process started for each connection with a given `endpoint` module
  Handles receiving messages from connection via request/response and
    calling the appropriate endpoint functions
  Calls back to the connection with the results of the function call, using :deliver
  """

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init([adapter, endpoint]) do
    {:ok, {adapter, endpoint}}
  end

  def handle_info({:request, message, peer, connection}, {adapter, endpoint} = state) do
    adapter.request(message, {endpoint, peer}, connection)
    {:noreply, state}
  end

  def handle_info({:response, message, peer, connection}, {adapter, endpoint} = state) do
    adapter.response(message, {endpoint, peer}, connection)
    {:noreply, state}
  end

  def handle_info({:error, reason}, {adapter, endpoint} = state) do
    adapter.error({endpoint, %{reason: reason}})
    {:noreply, state}
  end

  # defp deliver(result, connection) do
  #   send(connection, {:deliver, result})
  # end
end
