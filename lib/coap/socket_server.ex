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
  import Logger, only: [debug: 1, warn: 1]

  alias CoAP.Message

  def child_spec([_, connection_id, _] = args) do
    %{
      id: connection_id,
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      modules: [__MODULE__]
    }
  end

  def start(args), do: GenServer.start(__MODULE__, args)
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # init with port 5163/config (server), or 0 (client)

  # endpoint => server
  @doc """
    `init` functions for Server (e.g., phoenix endpoint) and Client

    When only `endpoint` and `port` (and optionally `config`) are provided, init for Server:
      Open a udp socket on the given port and store in state
      Initialize connections and monitors empty maps in state

    When `endpoint`, `host`, `port`, `token`, and `connection` are provided, init for Client:
      Opens a socket for sending (and receiving responses on a random listener)
      Does not listen on any known port for new messages
      Started by a `Connection` to deliver a client request message
  """
  def init([endpoint, port]), do: init([endpoint, port, []])

  def init([endpoint, {host, port, token}, connection]) do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, true}, {:reuseaddr, true}])

    ip = normalize_host(host)
    connection_id = {ip, port, token}

    ref = Process.monitor(connection)
    debug("Existing conn: #{inspect(connection)} w/ ref: #{inspect(ref)}")

    {:ok,
     %{
       port: 0,
       socket: socket,
       endpoint: endpoint,
       connections: %{connection_id => connection},
       monitors: %{ref => connection_id}
     }}
  end

  def init([endpoint, port, config]) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

    {:ok,
     %{
       port: port,
       socket: socket,
       endpoint: endpoint,
       connections: %{},
       monitors: %{},
       config: config
     }}
  end

  # Receive udp packets, forward to the appropriate connection
  def handle_info({:udp, _socket, peer_ip, peer_port, data}, state) do
    debug("CoAP socket received raw data #{to_hex(data)} from #{inspect({peer_ip, peer_port})}")

    message = Message.decode(data)

    {connection, new_state} =
      connection_for(message.request, {peer_ip, peer_port, message.token}, state)

    case connection do
      nil ->
        warn(
          "CoAP socket received message for lost connection from " <>
            "ip: #{inspect(peer_ip)}, port: #{inspect(peer_port)}.  Message: #{inspect(message)}"
        )

      c ->
        send(c, {:receive, message})
    end

    {:noreply, new_state}
  end

  # Deliver messages to be sent to a peer
  def handle_info({:deliver, message, {host, port} = _peer, tag}, %{socket: socket} = state) do
    data = Message.encode(message)

    ip = normalize_host(host)

    debug("CoAP socket sending raw data #{to_hex(data)} to #{inspect({ip, port})}")

    :telemetry.execute(
      [:coap_ex, :connection, :data_sent],
      %{size: byte_size(data)},
      %{host: ip, port: port, message_id: message.message_id, token: message.token, tag: tag}
    )

    :gen_udp.send(socket, ip, port, data)

    {:noreply, state}
  end

  # Handles message for completed connection
  # Removes complete connection from the registry and monitoring
  def handle_info({:DOWN, ref, :process, _from, reason}, state) do
    {host, port, _} = Map.get(state.monitors, ref)

    :telemetry.execute(
      [:coap_ex, :connection, :connection_ended],
      %{},
      %{type: type(state), host: host, port: port}
    )

    connection_complete(type(state), ref, reason, state)
  end

  defp connection_complete(:server, ref, reason, %{monitors: monitors} = state) do
    connection_id = Map.get(monitors, ref)
    connection = Map.get(state[:connections], connection_id)

    debug(
      "CoAP socket SERVER received DOWN:#{reason} in CoAP.SocketServer from:#{
        inspect(connection_id)
      }:#{inspect(connection)}:#{inspect(ref)}"
    )

    {:noreply,
     %{
       state
       | connections: Map.delete(state.connections, connection_id),
         monitors: Map.delete(monitors, ref)
     }}
  end

  defp connection_complete(:client, ref, reason, %{monitors: monitors} = state) do
    connection_id = Map.get(monitors, ref)
    connection = Map.get(state[:connections], connection_id)

    debug(
      "CoAP socket CLIENT received DOWN:#{reason} in CoAP.SocketServer from: #{
        inspect(connection_id)
      }:#{inspect(connection)}:#{inspect(ref)}"
    )

    {:stop, :normal, state}
  end

  defp connection_for(_request, connection_id, state) do
    connection = Map.get(state.connections, connection_id)

    case {connection, type(state)} do
      {nil, :server} ->
        {:ok, conn} = start_connection(self(), state.endpoint, connection_id, state.config)
        ref = Process.monitor(conn)
        debug("Started conn: #{inspect(conn)} for #{inspect(connection_id)}")

        {host, port, token} = connection_id

        :telemetry.execute(
          [:coap_ex, :connection, :connection_started],
          %{},
          %{host: host, port: port, token: token}
        )

        {
          conn,
          %{
            state
            | connections: Map.put(state.connections, connection_id, conn),
              monitors: Map.put(state.monitors, ref, connection_id)
          }
        }

      {nil, :client} ->
        # if this socket server was started to listen for a response as a client,
        # the associated connection that was started by the client has died
        {nil, state}

      _ ->
        {connection, state}
    end
  end

  defp start_connection(server, endpoint, peer, config) do
    DynamicSupervisor.start_child(
      CoAP.ConnectionSupervisor,
      {
        CoAP.Connection,
        [server, endpoint, peer, config]
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

  defp type(%{port: 0}), do: :client
  defp type(_), do: :server
end
