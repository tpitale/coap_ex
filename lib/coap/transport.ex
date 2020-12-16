defmodule CoAP.Transport do
  @moduledoc """
  Implements CoAP message layer

  # Message layer FSM

  See [CoAP Implementation Guidance (section
  2.5)](https://tools.ietf.org/id/draft-ietf-lwig-coap-05.html#message-layer)

  ```
  +-----------+ <-------M_CMD(reliable_send)-----+
  |           |            / TX(con)              \\
  |           |                                +--------------+
  |           | ---TIMEOUT(RETX_WINDOW)------> |              |
  |RELIABLE_TX|     / RR_EVT(fail)             |              |
  |           | ---------------------RX_RST--> |              | <----+
  |           |               / RR_EVT(fail)   |              |      |
  +-----------+ ----M_CMD(cancel)------------> |    CLOSED    |      |
   ^  |  |  \\  \\                               |              | --+  |
   |  |  |   \\  +-------------------RX_ACK---> |              |   |  |
   +*1+  |    \\                / RR_EVT(rx)    |              |   |  |
         |     +----RX_NON-------------------> +--------------+   |  |
         |       / RR_EVT(rx)                  ^ ^ ^ ^  | | | |   |  |
         |                                     | | | |  | | | |   |  |
         |                                     | | | +*2+ | | |   |  |
         |                                     | | +--*3--+ | |   |  |
         |                                     | +----*4----+ |   |  |
         |                                     +------*5------+   |  |
         |                +---------------+                       |  |
         |                |  ACK_PENDING  | <--RX_CON-------------+  |
         +----RX_CON----> |               |  / RR_EVT(rx)            |
           / RR_EVT(rx)   +---------------+ ---------M_CMD(accept)---+
                                                       / TX(ack)

  *1: TIMEOUT(RETX_TIMEOUT) / TX(con)
  *2: M_CMD(unreliable_send) / TX(non)
  *3: RX_NON / RR_EVT(rx)
  *4: RX_RST / REMOVE_OBSERVER
  *5: RX_ACK
  ```
  """
  use GenStateMachine

  alias CoAP.Message

  @ack_timeout 2_000
  @ack_random_factor 1.5
  @max_retransmit 4

  @type peer() :: URI.t()
  @type transport() :: pid()
  @type transport_opts() :: any()
  @type socket_init() ::
          ({peer(), transport(), transport_opts()} -> {:ok, pid()} | {:error, term()})
  @type host :: String.Chars.t() | :inet.ip_address()
  @type arg() ::
          {:peer, {host(), integer()}}
          | {:transport_opts, any()}
          | {:max_retransmit, integer()}
          | {:ack_timeout, integer()}
          | {:ack_random_factor, integer() | float()}
          | {:socket_init, socket_init()}
  @type args() :: arg()

  defstruct socket: nil,
            socket_ref: nil,
            socket_init: nil,
            peer: nil,
            retries: 0,
            max_retransmit: @max_retransmit,
            retransmit_timeout: 0,
            ack_timeout: @ack_timeout,
            ack_random_factor: @ack_random_factor,
            max_transmit_span: 0,
            transport_opts: nil,
            error: nil

  @type t :: %__MODULE__{
          socket: pid() | nil,
          socket_ref: reference() | nil,
          socket_init: socket_init() | nil,
          peer: %URI{} | nil,
          retries: integer(),
          max_retransmit: integer(),
          retransmit_timeout: integer(),
          ack_timeout: integer(),
          ack_random_factor: integer() | float(),
          max_transmit_span: integer(),
          transport_opts: any(),
          error: term() | nil
        }

  # Socket implementation is not linked to transport process, but monitored
  @callback start({peer(), transport(), transport_opts()}) :: GenServer.on_start()

  @doc false
  @spec start_link(args()) :: GenStateMachine.on_start()
  def start_link(args) do
    GenStateMachine.start_link(__MODULE__, args)
  end

  @impl GenStateMachine
  def init(args) do
    args = Enum.into(args, %{})

    %__MODULE__{}
    |> init_state(args)
    |> when_valid?(&cast_peer(&1, args))
    |> when_valid?(&cast_socket_init/1)
    |> when_valid?(&open_socket/1)
    |> case do
      %__MODULE__{error: nil} = s ->
        {:ok, :closed, s, timeouts(s)}

      %__MODULE__{error: reason} ->
        {:stop, reason}
    end
  end

  @impl GenStateMachine
  # STATE: _any
  def handle_event(:info, {:DOWN, ref, :process, _socket, _reason}, _, %{socket_ref: ref} = s) do
    s
    |> open_socket()
    |> case do
      %__MODULE__{error: nil} ->
        {:keep_state, s, timeouts(s)}

      %__MODULE__{error: reason} ->
        {:stop, {:socket, reason}, %{s | socket: nil}}
    end
  end

  def handle_event({:timeout, :max_transmit_span}, :close, _, s) do
    {:stop, :max_transmit_span, s}
  end

  # STATE: :closed
  def handle_event(:info, {:reliable_send, message}, :closed, s),
    do: handle_event(:info, {:reliable_send, message, nil}, :closed, s)

  def handle_event(:info, {:reliable_send, message, tag}, :closed, s) do
    send(s.socket, {:send, message, tag})
    actions = timeouts(s, {:state_timeout, s.retransmit_timeout, {:reliable_send, message, tag}})
    {:next_state, {:reliable_tx, message.message_id}, s, actions}
  end

  # STATE: {:reliable_tx, message_id}
  def handle_event(:info, {:reliable_send, m}, {:reliable_tx, id}, s),
    do: handle_event(:info, {:reliable_send, m, nil}, {:reliable_tx, id}, s)

  def handle_event(:info, {:reliable_send, _message, _tag}, {:reliable_tx, _id}, s) do
    {:keep_state_and_data, timeouts(s, :postpone)}
  end

  def handle_event(:info, :cancel, {:reliable_tx, _}, s) do
    {:next_state, :closed, s, timeouts(s)}
  end

  def handle_event(
        :info,
        {:recv, %Message{type: :reset, message_id: id}, _from},
        {:reliable_tx, id},
        s
      ) do
    {:stop, :fail, s}
  end

  def handle_event(
        :state_timeout,
        {:reliable_send, _, _, _},
        {:reliable_tx, _},
        %{
          retries: max_retries,
          max_retries: max_retries
        } = s
      ) do
    {:stop, :fail, s}
  end

  def handle_event(:state_timeout, {:reliable_send, message, tag} = event, {:reliable_tx, _}, s) do
    send(s.socket, {:send, message, tag})
    s = %{s | retransmit_timeout: s.retransmit_timeout * 2, retries: s.retries + 1}
    {:keep_state, s, timeouts(s, {:state_timeout, s.retransmit_timeout, event})}
  end

  # STATE: :ack_pending
  def handle_event(_type, _content, :ack_pending, s) do
    {:keep_state_and_data, timeouts(s)}
  end

  @impl GenStateMachine
  def terminate(_reason, _state, %{socket: nil}),
    do: :ok

  def terminate(_reason, _state, s) do
    send(s.socket, :close)
  end

  ###
  ### Priv
  ###
  defp timeouts(s, actions \\ []) do
    [{{:timeout, :max_transmit_span}, s.max_transmit_span, :close} | List.wrap(actions)]
  end

  defp when_valid?(%__MODULE__{error: nil} = state, fun),
    do: fun.(state)

  defp when_valid?(s, _), do: s

  defp init_state(s, args) do
    options =
      args
      |> Map.take([
        :ack_timeout,
        :ack_random_factor,
        :max_retransmit,
        :transport_opts,
        :socket_init
      ])

    s
    |> Map.merge(options, fn
      _key, v1, nil -> v1
      _key, _v1, v2 -> v2
    end)
    |> fill_retransmit_timeout()
    |> fill_max_transmit_span()
  end

  defp cast_peer(s, %{peer: {{a, b, c, d}, port}}) do
    uri = %URI{scheme: "coap", host: "#{a}.#{b}.#{c}.#{d}", port: port}
    %{s | peer: uri}
  end

  defp cast_peer(s, %{peer: {host, port}}) do
    uri = %URI{scheme: "coap", host: "#{host}", port: port}
    %{s | peer: uri}
  end

  defp cast_peer(s, _args),
    do: s

  defp cast_socket_init(%{peer: %URI{scheme: "coap"}} = s),
    do: %{s | socket_init: &CoAP.Transport.UDP.start/1}

  defp cast_socket_init(%{socket_init: init} = s) when is_function(init, 1),
    do: s

  defp cast_socket_init(s) do
    %{s | error: {:badarg, "Missing :peer or :socket_init"}}
  end

  defp open_socket(%{socket_init: init, peer: uri, transport_opts: opts} = s) do
    case init.({uri, self(), opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{s | socket: pid, socket_ref: ref}

      {:error, reason} ->
        %{s | error: reason}
    end
  end

  defp fill_retransmit_timeout(s) do
    %{s | retransmit_timeout: round(s.ack_timeout * s.ack_random_factor)}
  end

  defp fill_max_transmit_span(s) do
    %{
      s
      | max_transmit_span:
          round(s.ack_timeout * (:math.pow(2, s.max_retransmit) - 1) * s.ack_random_factor)
    }
  end
end
