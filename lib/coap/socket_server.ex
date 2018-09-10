defmodule CoAP.SocketServer do # => Listener
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, [0])
  end

  # init with port 5163/config (server), or 0 (client)

  # handler => server or client
  def init(port, handler) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

    {:ok, %{port: port, socket: socket, handler: handler, connections: %{}}}
  end

  # def server?(pid), do: GenServer.call(pid, :server)
  # def client?(pid), do: !server?(pid)

  # def handle_call(:server, %{port: port} = state) do
  #   {:reply, port > 0, state}
  # end

  def handle_info({:udp, _socket, peer_ip, peer_port, data}, %{connections: connections, handler: handler} = state) do
    token = token_for(data) # may cause an issue if we don't get a valid coap message
    connection_id = {peer_ip, peer_port, token}

    {:ok, connection} = Map.fetch(connections, connection_id) ||
                          start_connection(self(), handler, connection_id)

    send(connection, {:receive, data}) # TODO: if it's alive?
    # TODO: error if dead process

    {:noreply, %{state | connections: Map.put(connections, connection_id, connection)}
  end

  # def handle_cast({:deliver, peer, data}, state) # TODO: accept data for replies

  # TODO: move to Message?
  defp token_for(<<
    _version_type::binary-size(4),
    token_length::unsigned-integer-size(4),
    _unused::binary-size(24),
    payload::binary
  >>) do
    # TODO: Should we just use Message.decode().token?
    <<token::binary-size(token_length), _rest:: binary>> = payload

    token
  end

  defp start_connection(server, handler, peer) do
    DynamicSupervisor.start_child(
      CoAP.ConnectionSupervisor, # TODO: start this in the CoAP application
      CoAP.Connection,
      [server, handler, peer]
    )
  end
end
