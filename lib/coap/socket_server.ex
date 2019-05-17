defmodule CoAP.SocketServer do
  @moduledoc """
    CoAP.SocketServer holds a reference to a server, or is held by a client.
    It contains the UDP port either listening (for a server) or used by a client.

    When a new UDP packet is received, the socket_server attempts to look up an
    existing connection, or establish a new connection as necessary.

    This registry of connections is mapped by a connection_id, a tuple of
    `{ip, port, token}` so that subsequent messages exchanged will be routed
    to the appropriate `CoAP.Connection`.

    A socket_server should generally not be started directly. It will be started
    automatically by a `CoAP.Client` or by a server like `CoAP.Phoenix.Listener`.

    A socket_server will receive and handle a few messages. `:udp` from the udp socket,
    `:deliver` from the `CoAP.Connection` when a message is being sent, and `:DOWN`
    when a monitored connection is complete and the process ends.
  """

  use GenServer

  import CoAP.Util.BinaryFormatter, only: [to_hex: 1]
  import Logger, only: [debug: 1]

  alias CoAP.Message

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # init with port 5163/config (server), or 0 (client)

  # endpoint => server
  def init([port, endpoint]) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

    {:ok, %{port: port, socket: socket, endpoint: endpoint, connections: %{}, monitors: %{}}}
  end

  # Used by Connection to start a udp port
  # endpoint => client
  def init([endpoint, {host, port, token}, connection]) do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, true}, {:reuseaddr, true}])

    # TODO: use handle_continue to do this
    ip = normalize_host(host)
    connection_id = {ip, port, token}

    ref = Process.monitor(connection)

    {:ok,
     %{
       port: 0,
       socket: socket,
       endpoint: endpoint,
       connections: %{connection_id => connection},
       monitors: %{ref => connection_id}
     }}
  end

  def server?(pid), do: GenServer.call(pid, :server)
  def client?(pid), do: !server?(pid)

  def handle_call(:server, %{port: port} = state) do
    {:reply, port > 0, state}
  end

  def handle_info(
        {:udp, _socket, peer_ip, peer_port, data},
        %{endpoint: endpoint} = state
      ) do
    debug("CoAP socket received raw data #{to_hex(data)} from #{inspect({peer_ip, peer_port})}")

    message = Message.decode(data)
    # token = token_for(data) # may cause an issue if we don't get a valid coap message
    connection_id = {peer_ip, peer_port, message.token}
    connection = Map.get(state.connections, connection_id)

    {connection, connections, monitors} =
      case connection do
        nil ->
          {:ok, conn} = start_connection(self(), endpoint, connection_id)

          {
            conn,
            Map.put(state.connections, connection_id, conn),
            Map.put(state.monitors, Process.monitor(conn), connection_id)
          }

        _ ->
          {connection, state.connections, state.monitors}
      end

    # TODO: if it's alive?
    send(connection, {:receive, message})
    # TODO: error if dead process

    {:noreply, %{state | connections: connections, monitors: monitors}}
  end

  # TODO: accept data for replies
  def handle_info({:deliver, message, {host, port} = _peer}, %{socket: socket} = state) do
    data = Message.encode(message)

    ip = normalize_host(host)

    debug("CoAP socket sending raw data #{to_hex(data)} to #{inspect({ip, port})}")

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
  def handle_info({:DOWN, ref, :process, _from, reason}, %{monitors: monitors} = state) do
    connection_id = Map.get(monitors, ref)

    debug(
      "CoAP socket received DOWN:#{reason} in CoAP.SocketServer from:#{inspect(connection_id)}"
    )

    {:noreply,
     %{
       state
       | connections: Map.delete(state.connections, connection_id),
         monitors: Map.delete(monitors, ref)
     }}
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

  defp normalize_host(host) when is_tuple(host), do: host

  defp normalize_host(host) when is_binary(host) do
    host
    |> to_charlist()
    |> normalize_host()
  end

  defp normalize_host(host) when is_list(host) do
    host
    |> :inet.getaddr(:inet)
    |> case do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end
end
