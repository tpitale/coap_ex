defmodule CoAP.Test.Support.LocalAdapter do
  @moduledoc false
  use GenServer

  alias CoAP.Message
  alias CoAP.Transport

  @behaviour CoAP.Transport

  @impl Transport
  def start(peer, transport, opts),
    do: GenServer.start(__MODULE__, {peer, transport, opts})

  @impl GenServer
  def init({peer, transport, server}) do
    server = server || (&default/2)
    {:ok, %{peer: peer, transport: transport, server: server}}
  end

  @impl GenServer
  def handle_info({:send, request}, s) do
    callback = fn response -> send(s.transport, {:recv, response, s.peer}) end

    try do
      s.server.(request, callback)
    rescue
      FunctionClauseError ->
        default(request, callback)
    end

    {:noreply, s}
  end

  def handle_info(:close, s), do: {:stop, :normal, s}

  defp default(%Message{type: :ack}, _cb) do
    :ok
  end
end
