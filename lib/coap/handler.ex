defmodule CoAP.Handler do
  @moduledoc """
  Thin wrapper process started for each connection with a given `endpoint` module
  Handles receiving messages from connection via request/response and
    calling the appropriate endpoint functions
  Calls back to the connection with the results of the function call, using :deliver
  """
  use GenServer

  defstruct adapter: nil, endpoint: nil, connection: nil, ref: nil

  def child_spec(args) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [args]}, restart: :transient}
  end

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init([adapter, endpoint, connection]) do
    ref = Process.monitor(connection)
    s = %__MODULE__{adapter: adapter, endpoint: endpoint, connection: connection, ref: ref}
    {:ok, s}
  end

  @impl GenServer
  def handle_info({:request, message, peer}, s) do
    s.adapter.request(message, {s.endpoint, peer}, s.connection)
    {:noreply, s}
  end

  def handle_info({:response, message, peer}, s) do
    s.adapter.response(message, {s.endpoint, peer}, s.connection)
    {:noreply, s}
  end

  def handle_info({:error, reason}, s) do
    s.adapter.error({s.endpoint, %{reason: reason}})
    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{ref: ref} = s) do
    {:stop, :normal, s}
  end
end
