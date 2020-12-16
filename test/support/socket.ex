defmodule CoAP.Test.Support.Socket do
  @moduledoc false
  use GenServer

  alias CoAP.Transport

  @behaviour CoAP.Transport

  @impl Transport
  def start(args),
    do: GenServer.start(__MODULE__, args)

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
