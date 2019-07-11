defmodule CoAP.Acceptor do
  # Takes a listen_socket
  # Accepts on that listen_socket
  # Passes the resulting socket back to SecureSocketServer, which takes ownership, does handshake
  # Loops
  use GenServer

  # This could maybe be done without a GenServer …

  import Logger, only: [debug: 1]

  @accept_timeout 1000

  def start_link([server, listen_socket]) do
    GenServer.start_link(__MODULE__, [server, listen_socket])
  end

  def init([server, listen_socket]) do
    send(self(), :accept)

    {:ok, [server, listen_socket]}
  end

  def handle_info(:accept, [server, listen_socket] = state) do
    :ssl.transport_accept(listen_socket, @accept_timeout)
    |> process_with(server)

    # Loop
    send(self(), :accept)

    {:noreply, state}
  end

  defp process_with({:ok, socket}, server) do
    send(server, {:process, socket})
  end

  defp process_with({:error, reason}, _server) do
    debug("Error accepting DTLS socket: #{reason}")
  end
end
