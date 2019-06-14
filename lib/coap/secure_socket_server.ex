defmodule CoAP.SecureSocketServer do
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

  # TODO: make this a supervisor with SecureSocket children for each accept

  use GenServer

  import CoAP.Util.BinaryFormatter, only: [to_hex: 1]
  import Logger, only: [debug: 1]

  alias CoAP.Message

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # init with port 5163/config (server), or 0 (client)

  # endpoint => server
  @doc """
    init function for a server e.g., phoenix endpoint

    Open a udp socket on the given port and store in state
    Initialize connections and monitors empty maps in state
  """
  def init([port, endpoint, ssl_config]) do
    {:ok, listen_socket} =
      :ssl.listen(port, [:binary, {:active, true}, {:reuseaddr, true}, {:protocol, :dtls}])

    {:ok, socket} = :ssl.transport_accept(listen_socket)

    {:ok,
     %{
       port: port,
       socket: socket,
       endpoint: endpoint,
       ssl_config: ssl_config,
       connections: %{},
       monitors: %{}
     }}
  end

  # Used by Connection to start a udp port
  # endpoint => client
  @doc """
    init function for a client

    Opens a socket for sending (and receiving responses on a random listener)
    Does not listen on any known port for new messages
    Started by a `Connection` to deliver a client request message
  """
  # def init([endpoint, {host, port, token}, connection]) do
  #   {:ok, socket} = :gen_udp.open(0, [:binary, {:active, true}, {:reuseaddr, true}])
  #
  #   # TODO: use handle_continue to do this
  #   ip = normalize_host(host)
  #   connection_id = {ip, port, token}
  #
  #   ref = Process.monitor(connection)
  #
  #   {:ok,
  #    %{
  #      port: 0,
  #      socket: socket,
  #      endpoint: endpoint,
  #      connections: %{connection_id => connection},
  #      monitors: %{ref => connection_id}
  #    }}
  # end

  @doc """
    Receive udp packets, forward to the appropriate connection
  """
  def handle_info({:ssl, socket, data}, state) do
    {:ok, {peer_ip, peer_port}} = :ssl.peername(socket)

    debug("CoAP socket received raw data #{to_hex(data)} from #{inspect({peer_ip, peer_port})}")

    message = Message.decode(data)

    {connection, new_state} = connection_for({peer_ip, peer_port, message.token}, state)

    # TODO: if it's alive?
    send(connection, {:receive, message})
    # TODO: error if dead process

    {:noreply, new_state}
  end

  @doc """
    Deliver messages to be sent to a peer
  """
  def handle_info({:deliver, message, {host, port} = _peer}, %{socket: socket} = state) do
    data = Message.encode(message)

    ip = normalize_host(host)

    debug("CoAP socket sending raw data #{to_hex(data)} to #{inspect({ip, port})}")

    :ssl.send(socket, data)

    {:noreply, state}
  end

  # TODO: Do we need to do this when using connection supervisor?
  @doc """
    Handles message for completed connection
    Removes complete connection from the registry and monitoring
  """
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

  defp connection_for(connection_id, state) do
    connection = Map.get(state.connections, connection_id)

    case connection do
      nil ->
        {:ok, conn} = start_connection(self(), state.endpoint, connection_id)

        {
          conn,
          %{
            state
            | connections: Map.put(state.connections, connection_id, conn),
              monitors: Map.put(state.monitors, Process.monitor(conn), connection_id)
          }
        }

      _ ->
        {connection, state}
    end
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
