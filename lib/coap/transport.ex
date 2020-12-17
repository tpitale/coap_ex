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

  @type client() :: pid() | term()
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

  @typedoc """
  * `:rr_cancel`: transport received a cancel event
  * `:rr_fail`: transport failed, due to reset or timeout
  * `:rr_rx`: transport received an ACK
  """
  @type rr_message_content :: :rr_cancel | :rr_fail | {:rr_rx, Message.t()}

  @typedoc """
  Messages to Request/Receive layer
  """
  @type rr_message :: {pid(), rr_message_content()}

  @typedoc """
  Messages from Socket to Transport layer
  """
  @type socket_message :: {:recv, Message.t(), {:inet.ip_address(), :inet.port_number()}}

  defstruct client: nil,
            socket: nil,
            socket_ref: nil,
            socket_init: nil,
            peer: nil,
            retries: 0,
            max_retransmit: @max_retransmit,
            retransmit_timeout: 0,
            ack_timeout: @ack_timeout,
            ack_random_factor: @ack_random_factor,
            transport_opts: nil,
            error: nil

  @type t :: %__MODULE__{
          client: client() | nil,
          socket: pid() | nil,
          socket_ref: reference() | nil,
          socket_init: socket_init() | nil,
          peer: %URI{} | nil,
          retries: integer(),
          max_retransmit: integer(),
          retransmit_timeout: integer(),
          ack_timeout: integer(),
          ack_random_factor: integer() | float(),
          transport_opts: any(),
          error: term() | nil
        }

  # Socket implementation is not linked to transport process, but monitored
  @callback start({peer(), transport(), transport_opts()}) :: GenServer.on_start()

  @doc false
  @spec start_link(client(), args()) :: GenStateMachine.on_start()
  def start_link(client, args) do
    GenStateMachine.start_link(__MODULE__, {client, args})
  end

  @doc false
  @spec start(client(), args()) :: GenStateMachine.on_start()
  def start(client, args) do
    GenStateMachine.start(__MODULE__, {client, args})
  end

  @impl GenStateMachine
  def init({client, args}) do
    args = Enum.into(args, %{})

    %__MODULE__{client: client}
    |> init_state(args)
    |> when_valid?(&cast_peer(&1, args))
    |> when_valid?(&cast_socket_init/1)
    |> when_valid?(&open_socket/1)
    |> case do
      %__MODULE__{error: nil} = s ->
        {:ok, :closed, s}

      %__MODULE__{error: reason} ->
        {:stop, reason}
    end
  end

  @impl GenStateMachine
  # STATE: _any
  def handle_event(
        :info,
        {:DOWN, ref, :process, _socket, _reason},
        _,
        %__MODULE__{socket_ref: ref} = s
      ) do
    s
    |> open_socket()
    |> case do
      %__MODULE__{error: nil} ->
        {:keep_state, s}

      %__MODULE__{error: reason} ->
        {:stop, {:socket, reason}, %{s | socket: nil}}
    end
  end

  def handle_event(:info, {:DOWN, _, _, _, _}, _, _s),
    do: :keep_state_and_data

  # STATE: :closed
  def handle_event(:info, {:reliable_send, message}, :closed, s),
    do: handle_event(:info, {:reliable_send, message, nil}, :closed, s)

  def handle_event(:info, {:reliable_send, message, tag}, :closed, s) do
    send(s.socket, {:send, message, tag})

    {:next_state, {:reliable_tx, message.message_id}, s,
     {:state_timeout, s.retransmit_timeout, {:reliable_send, message, tag}}}
  end

  def handle_event(:info, {:recv, %Message{message_id: id, type: :con} = message, _from}, :closed, s) do
    send(s.client, {self(), {:rr_rx, message}})
    # No timeout, but RR layer should take care of ack'ing message in a
    # reasonble time
    {:next_state, {:ack_pending, id}, s}
  end

  # STATE: {:reliable_tx, message_id}
  def handle_event(:info, {:reliable_send, m}, {:reliable_tx, id}, s),
    do: handle_event(:info, {:reliable_send, m, nil}, {:reliable_tx, id}, s)

  def handle_event(:info, {:reliable_send, _message, _tag}, {:reliable_tx, _id}, _s) do
    {:keep_state_and_data, :postpone}
  end

  def handle_event(:info, :cancel, {:reliable_tx, _}, s) do
    send(s.client, {self(), :rr_cancel})
    {:next_state, :closed, s}
  end

  def handle_event(
        :info,
        {:recv, %Message{type: :ack, message_id: id} = m, _from},
        {:reliable_tx, id},
        s
      ) do
    send(s.client, {self(), {:rr_rx, m}})
    {:next_state, :closed, s}
  end

  def handle_event(
        :info,
        {:recv, %Message{type: :reset, message_id: id}, _from},
        {:reliable_tx, id},
        s
      ) do
    send(s.client, {self(), :rr_fail})
    {:next_state, :closed, s}
  end

  def handle_event(
        :state_timeout,
        {:reliable_send, _, _},
        {:reliable_tx, _},
        %__MODULE__{
          retries: max_retransmit,
          max_retransmit: max_retransmit
        } = s
      ) do
    send(s.client, {self(), :rr_fail})
    {:next_state, :closed, s}
  end

  def handle_event(:state_timeout, {:reliable_send, message, tag} = event, {:reliable_tx, _}, s) do
    send(s.socket, {:send, message, tag})
    s = %{s | retransmit_timeout: s.retransmit_timeout * 2, retries: s.retries + 1}
    {:keep_state, s, {:state_timeout, s.retransmit_timeout, event}}
  end

  # STATE: :ack_pending
  def handle_event(_type, _content, :ack_pending, _s) do
    :keep_state_and_data
  end

  # For tests/debugging purpose
  def handle_event(:info, :reset, _, s),
    do: {:next_state, :closed, s}

  def handle_event({:call, from}, :state_name, state_name, _s),
    do: {:keep_state_and_data, {:reply, from, state_name}}

  @impl GenStateMachine
  def terminate(_reason, _state, %{socket: nil}),
    do: :ok

  def terminate(_reason, _state, s) do
    send(s.socket, :close)
  end

  ###
  ### Priv
  ###
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
    |> validate_ack_random_factor()
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
    %{s | retransmit_timeout: __retransmit_timeout__(s.ack_timeout, s.ack_random_factor)}
  end

  defp validate_ack_random_factor(%{ack_random_factor: factor} = s)
       when is_float(factor) and factor >= 1.0,
       do: s

  defp validate_ack_random_factor(s),
    do: %{s | error: {:badarg, :ack_random_factor, s.ack_random_factor}}

  def __max_transmit_wait__(ack_timeout, max_retransmit, ack_random_factor \\ @ack_random_factor) do
    round(ack_timeout * (:math.pow(2, max_retransmit + 1) - 1) * ack_random_factor)
  end

  def __retransmit_timeout__(ack_timeout, ack_random_factor \\ @ack_random_factor) do
    random = :rand.uniform() * ack_timeout * (ack_random_factor - 1)
    round(ack_timeout + random)
  end
end
