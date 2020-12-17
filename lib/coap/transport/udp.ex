defmodule CoAP.Transport.UDP do
  @moduledoc """
  Implements UDP specific transport

  Integration with transport layer is done through:
  * `CoAP.Transport.start/1` callback
  * received messages:
    * `{:send, CoAP.Message.t(), tag :: any()}`
    * `:close`
  * emitted messages:
    * `{:recv, CoAP.Message.t(), from :: {:inet.ip_address(), :inet.port_number()}}`
  """
  use GenServer

  import CoAP.Util

  alias CoAP.Message
  alias CoAP.Transport

  @behaviour Transport

  defstruct socket: nil, host: nil, port: nil, transport: nil

  # No activity timeout: 5 minutes
  @timeout 5 * 60 * 1000

  @doc false
  @impl Transport
  def start({%URI{host: host, port: port}, transport, _opts}) do
    with {:ok, host_ip} <- resolve_ip(host),
         {:ok, pid} <-
           GenServer.start(__MODULE__, {host_ip, port, transport},
             name: {:global, {__MODULE__, host_ip, port}}
           ) do
      {:ok, pid}
    else
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl GenServer
  def init({host_ip, port, transport}) do
    # Open UDP socket for sending request, as 'client'
    case :gen_udp.open(0, [:binary, {:active, true}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket, host: host_ip, port: port, transport: transport},
         @timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl GenServer
  def handle_info({:send, message}, s) do
    data = Message.encode(message)
    :ok = :gen_udp.send(s.socket, s.host, s.port, data)
    {:noreply, s, @timeout}
  end

  def handle_info({:udp, _socket, peer_ip, peer_port, data}, s) do
    message = Message.decode(data)
    send(s.transport, {:recv, message, {peer_ip, peer_port}})
    {:noreply, s, @timeout}
  end

  def handle_info(:timeout, s), do: {:stop, :normal, s}

  def handle_info(:close, s), do: {:stop, :normal, s}

  @impl GenServer
  def terminate(_reason, s) do
    :gen_udp.close(s.socket)
  end
end
