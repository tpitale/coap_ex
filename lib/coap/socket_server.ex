defmodule CoAP.SocketServer do
  use GenServer

  import Logger, only: [debug: 1]

  alias CoAP.Message

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # init with port 5163/config (server), or 0 (client)

  # endpoint => server
  def init([port, endpoint]) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

    {:ok, %{port: port, socket: socket, endpoint: endpoint, connections: %{}}}
  end

  # Used by Connection to start a udp port
  # endpoint => client
  def init([endpoint, connection_id, connection]) do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, true}, {:reuseaddr, true}])

    {:ok,
     %{port: 0, socket: socket, endpoint: endpoint, connections: %{connection_id => connection}}}
  end

  def server?(pid), do: GenServer.call(pid, :server)
  def client?(pid), do: !server?(pid)

  def handle_call(:server, %{port: port} = state) do
    {:reply, port > 0, state}
  end

  def handle_info(
        {:udp, _socket, peer_ip, peer_port, data},
        %{connections: connections, endpoint: endpoint} = state
      ) do
    message = Message.decode(data)
    # token = token_for(data) # may cause an issue if we don't get a valid coap message
    connection_id = {peer_ip, peer_port, message.token}

    # TODO: store ref for connection process?
    # TODO: Monitor and remove connection when terminating?
    connection =
      case Map.get(connections, connection_id) ||
             start_connection(self(), endpoint, connection_id) do
        {:ok, conn} -> conn
        conn -> conn
      end

    # TODO: if it's alive?
    send(connection, {:receive, message})
    # TODO: error if dead process

    {:noreply, %{state | connections: Map.put(connections, connection_id, connection)}}
  end

  # TODO: accept data for replies
  def handle_info({:deliver, message, {ip, port} = _peer}, %{socket: socket} = state) do
    data = Message.encode(message)

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

  # TODO: Do we need to do this when using connection supervisor?
  # TODO: Can we use this to remove dead connections?
  def handle_info({:EXIT, from, reason}, state) do
    debug("Received exit in CoAP.SocketServer from: #{inspect(from)}, with #{inspect(reason)}")

    {:noreply, state}
  end

  # TODO: move to CoAP
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
