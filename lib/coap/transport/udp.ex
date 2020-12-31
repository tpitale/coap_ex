defmodule CoAP.Transport.UDP do
  @moduledoc """
  Implements UDP specific transport
  """
  use GenServer

  import CoAP.Util

  alias CoAP.Message
  alias CoAP.Transport

  @behaviour Transport

  defstruct socket: nil, peer_ip: nil, peer: nil, transport: nil

  # No activity timeout: 5 minutes
  @timeout 5 * 60 * 1000

  @doc false
  @impl Transport
  def start(peer, transport, opts) do
    case GenServer.start(__MODULE__, {peer, transport, opts}, name: {:global, {__MODULE__, peer}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl GenServer
  def init({{host, _port} = peer, transport, _opts}) do
    with {:ok, host_ip} <- resolve_ip(host),
         # Open UDP socket for sending request, as 'client'
         {:ok, socket} <- :gen_udp.open(0, [:binary, {:active, true}, {:reuseaddr, true}]) do
      {:ok, %__MODULE__{socket: socket, peer_ip: host_ip, peer: peer, transport: transport},
       @timeout}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl GenServer
  def handle_info({:send, message}, %{peer_ip: peer_ip, peer: {_, port}} = s) do
    data = Message.encode(message)
    :ok = :gen_udp.send(s.socket, peer_ip, port, data)
    {:noreply, s, @timeout}
  end

  def handle_info(
        {:udp, _socket, peer_ip, peer_port, data},
        %{peer_ip: peer_ip, peer: {_peer_host, peer_port} = peer} = s
      ) do
    message = Message.decode(data)
    send(s.transport, {:recv, message, peer})
    {:noreply, s, @timeout}
  end

  def handle_info(:timeout, s), do: {:stop, :normal, s}

  def handle_info(:close, s), do: {:stop, :normal, s}

  @impl GenServer
  def terminate(_reason, s) do
    :gen_udp.close(s.socket)
  end
end
