defmodule CoAP.SocketServer do # => Listener
  use GenServer

  alias CoAP.Message

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # init with port 5163/config (server), or 0 (client)

  # endpoint => server or client
  def init({port, endpoint}) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

    {:ok, %{port: port, socket: socket, endpoint: endpoint, connections: %{}}}
  end

  # def server?(pid), do: GenServer.call(pid, :server)
  # def client?(pid), do: !server?(pid)

  # def handle_call(:server, %{port: port} = state) do
  #   {:reply, port > 0, state}
  # end

  def handle_info({:udp, _socket, peer_ip, peer_port, data}, %{connections: connections, endpoint: endpoint} = state) do
    message = Message.decode(data)
    # token = token_for(data) # may cause an issue if we don't get a valid coap message
    connection_id = {peer_ip, peer_port, message.token}

    # TODO: store ref for connection process?
    # TODO: Monitor and remove connection when terminating?
    {:ok, connection} = Map.fetch(connections, connection_id) ||
                          start_connection(self(), endpoint, connection_id)

    send(connection, {:receive, message}) # TODO: if it's alive?
    # TODO: error if dead process

    {:noreply, %{state | connections: Map.put(connections, connection_id, connection)}}
  end

  def handle_info({:deliver, peer, message}, %{socket: socket} = state) do # TODO: accept data for replies
    data = Message.encode(message)
    {ip, port} = peer

    :gen_udp.send(socket, ip, port, data)

    {:noreply, state}
  end

  # TODO: move to Message?
  # defp token_for(<<
  #   _version_type::binary-size(4),
  #   token_length::unsigned-integer-size(4),
  #   _unused::binary-size(24),
  #   payload::binary
  # >>) do
  #   # TODO: Should we just use Message.decode().token?
  #   <<token::binary-size(token_length), _rest:: binary>> = payload
  #
  #   token
  # end

  defp start_connection(server, endpoint, peer) do
    DynamicSupervisor.start_child(
      CoAP.ConnectionSupervisor,
      {
        CoAP.Connection,
        [server, endpoint, peer]
      }
    )
  end
end
