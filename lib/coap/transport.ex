defmodule CoAP.Transport do
  @moduledoc """
  Implements CoAP message layer
  """
  use GenStateMachine

  import CoAP.Util.BinaryFormatter, only: [to_hex: 1]
  import Logger, only: [debug: 1]

  alias CoAP.Message

  @ack_timeout 2_000
  @ack_random_factor 1.5
  @max_retransmit 4

  defstruct socket: nil,
            peer: nil,
            peer_ip: nil,
            retries: 0,
            max_retransmit: @max_retransmit,
            retransmit_timeout: 0,
            ack_timeout: @ack_timeout,
            ack_random_factor: @ack_random_factor

  @type t :: %__MODULE__{
          socket: :gen_udp.socket() | nil,
          peer: %URI{} | nil,
          peer_ip: :inet.ip_address(),
          retries: integer(),
          max_retransmit: integer(),
          retransmit_timeout: integer(),
          ack_timeout: integer(),
          ack_random_factor: integer() | float()
        }

  @type host :: String.Chars.t() | :inet.ip_address()
  @type arg() ::
          {:peer, {host(), integer()}}
          | {:max_retransmit, integer()}
          | {:ack_timeout, integer()}
          | {:ack_random_factor, integer() | float()}
  @type args() :: arg()

  @doc false
  @spec start_link(args()) :: GenStateMachine.on_start()
  def start_link(args) do
    GenStateMachine.start_link(__MODULE__, args)
  end

  @impl GenStateMachine
  def init(args) do
    args = Enum.into(args, %{})

    with args <- Enum.into(args, %{}),
         {:ok, s} <- init_state(args),
         {:ok, uri} <- get_peer(args),
         {:ok, peer_ip} <- resolve_ip(uri),
         {:ok, socket} <- open_socket(uri) do
      {:ok, :closed, %{s | peer: uri, peer_ip: peer_ip, socket: socket}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenStateMachine
  def handle_event(:info, {:reliable_send, message, tag}, :closed, s) do
    data = Message.encode(message)
    :ok = do_send_con(data, message, tag, s)

    {:next_state, :reliable_tx, s,
     {:state_timeout, s.retransmit_timeout, {:reliable_send, message, tag, data}}}
  end

  def handle_event(_type, _content, :closed, _state) do
    :keep_state_and_data
  end

  def handle_event(:state_timeout, {:reliable_send, message, tag, data} = event, :reliable_tx, s) do
    :ok = do_send_con(data, message, tag, s)
    s = %{s | retransmit_timeout: s.retransmit_timeout * 2}
    {:next_state, :reliable_tx, s, {:state_timeout, s.retransmit_timeout, event}}
  end

  def handle_event(_type, _content, :reliable_tx, _state) do
    :keep_state_and_data
  end

  def handle_event(_type, _content, :ack_pending, _state) do
    :keep_state_and_data
  end

  ###
  ### Priv
  ###
  defp do_send_con(data, message, tag, s) do
    debug("CoAP socket sending raw data #{to_hex(data)} to #{s.peer}")

    :telemetry.execute(
      [:coap_ex, :connection, :data_sent],
      %{size: byte_size(data)},
      %{
        host: s.peer.host,
        port: s.peer.port,
        message_id: message.message_id,
        token: message.token,
        tag: tag
      }
    )

    :ok = :gen_udp.send(s.socket, s.peer_ip, s.peer.port, data)
  end

  defp init_state(args) do
    options =
      args
      |> Map.take([:ack_timeout, :ack_random_factor, :max_retransmit])

    s =
      Map.merge(%__MODULE__{}, options, fn
        _key, v1, nil -> v1
        _key, _v1, v2 -> v2
      end)

    s = %{s | retransmit_timeout: round(s.ack_timeout * s.ack_random_factor)}

    {:ok, s}
  end

  defp get_peer(%{peer: {{a, b, c, d}, port}}) do
    uri = %URI{scheme: "coap", host: "#{a}.#{b}.#{c}.#{d}", port: port}
    {:ok, uri}
  end

  defp get_peer(%{peer: {host, port}}) do
    uri = %URI{scheme: "coap", host: "#{host}", port: port}
    {:ok, uri}
  end

  defp get_peer(args),
    do: {:error, {:badarg, args}}

  defp resolve_ip(%URI{host: host}) do
    '#{host}'
    |> :inet.getaddr(:inet)
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, {:invalid_host, reason}}
    end
  end

  defp open_socket(%URI{scheme: "coap", port: port}) do
    port
    |> :gen_udp.open([:binary, {:active, true}, {:reuseaddr, true}])
    |> case do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end
end
