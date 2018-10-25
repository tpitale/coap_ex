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

  # TODO: this process is blocked when calling endpoint
  # TODO: we may want to instrument/log the queue depth here
  # It _should not_ be an issue because this process is already per-peer connection

  def handle_info({:request, message, peer, connection}, {adapter, endpoint} = state) do
    adapter.request(message, {endpoint, peer}, connection)
    {:noreply, state}
  end

  def handle_info({:response, message, peer, connection}, {adapter, endpoint} = state) do
    adapter.response(message, {endpoint, peer}, connection)
    {:noreply, state}
  end

  def handle_info(:ack, {adapter, endpoint} = state) do
    adapter.ack({endpoint, {}})
    {:noreply, state}
  end

  def handle_info(:error, {adapter, endpoint} = state) do
    adapter.error({endpoint, {}})
    {:noreply, state}
  end

  # defp deliver(result, connection) do
  #   send(connection, {:deliver, result})
  # end
end
