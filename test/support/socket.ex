defmodule CoAP.Test.Support.Socket do
  @moduledoc false
  use GenServer

  alias CoAP.Transport

  @behaviour CoAP.Transport

  @impl Transport
  def start(peer, transport, opts),
    do: GenServer.start(__MODULE__, {peer, transport, opts})

  @impl GenServer
  def init({_peer, _t, test_pid}) do
    {:ok, test_pid}
  end

  @impl GenServer
  def handle_info(info, test_pid) do
    send(test_pid, info)
    {:noreply, test_pid}
  end
end
