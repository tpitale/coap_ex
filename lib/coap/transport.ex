defmodule CoAP.Transport do
  @moduledoc """
  Implements CoAP Message layer.

  CoAP has been designed for using datagram-oriented, unreliable transport, like
  UDP. A lightweight reliability layer is described in CoAP specification and
  called "Message layer".

  This module implements the "Message layer" FSM and delegates socket
  communication to separate modules.

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

  # Protocol stack integration

  CoAP Message layer communicates with:
  * lower socket layer, like UDP, DTLS or even a reliable one like websocket;
  * higher request/response layer, as client or server.

  ## Message <-> socket communication

  * To socket:
    * `TX(ack)`: `{:send, %Message{type: :ack}}`
    * `TX(con)`: `{:send, %Message{type: :con}}`
    * `TX(non)`: `{:send, %Message{type: :non}}`
  * From socket:
    * `RX_RST`: `{:recv, %Message{type: :reset}, peer()}`
    * `RX_ACK`: `{:recv, %Message{type: :ack}, peer()}`
    * `RX_NON`: `{:recv, %Message{type: :non}, peer()}`
    * `RX_CON`: `{:recv, %Message{type: :con}, peer()}`

  ## Message <> Request/Response communication

  * to RR
    * `RR_EVT(fail)`: `{:rr_fail, Message.id(), reason}`
    * `RR_EVT(rx)`: `{:rr_rx, Message.t(), peer()}`

  * from RR
    * `M_CMD(cancel)`: `{:cancel, Message.id()}`
    * `M_CMD(reliable_send)`: `%Message{type: :con}`
    * `M_CMD(unreliable_send)`: `%Message{type: :non}`
    * `M_CMD(accept)`: `%Message{type: :ack}`


  """
  use GenStateMachine

  alias CoAP.Message

  @type client() :: pid() | term()
  @type peer() :: {binary(), :inet.port_number()}
  @type transport() :: pid()
  @type socket_opts() :: any()
  @type socket_adapter() :: module()
  @type host :: String.Chars.t() | :inet.ip_address()
  @type arg() ::
          {:max_retransmit, integer()}
          | {:ack_timeout, integer()}
          | {:ack_random_factor, integer() | float()}
          | {:socket_adapter, module()}
          | {:socket_opts, any()}
          | term()
  @type args() :: arg()

  @type rr_fail_reason :: :reset | :timeout

  @typedoc """
  * `{:rr_fail, Message.id(), rr_fail_reason()}`: transport failed, due to reset or timeout
  * `{:rr_rx, Message.t()}`: transport received a message
  """
  @type rr_message_content ::
          {:rr_fail, Message.id(), rr_fail_reason()} | {:rr_rx, Message.t(), peer()}

  @typedoc """
  Messages to Request/Receive layer
  """
  @type rr_message :: {pid(), rr_message_content()}

  @typedoc """
  Messages from Socket to Transport layer
  """
  @type socket_message :: {:recv, Message.t(), peer()} | {:send, Message.t()}

  defmodule State do
    @moduledoc false
    alias CoAP.Transport

    @ack_timeout 2_000
    @ack_random_factor 1.5
    @max_retransmit 4

    defstruct client: nil,
              socket: nil,
              socket_ref: nil,
              socket_adapter: CoAP.Transport.UDP,
              peer: nil,
              retries: 0,
              max_retransmit: @max_retransmit,
              retransmit_timeout: 0,
              ack_timeout: @ack_timeout,
              ack_random_factor: @ack_random_factor,
              socket_opts: nil,
              error: nil

    @type t :: %__MODULE__{
            client: Transport.client() | nil,
            socket: pid() | nil,
            socket_ref: reference() | nil,
            socket_adapter: module() | nil,
            peer: Transport.peer() | nil,
            retries: integer(),
            max_retransmit: integer(),
            retransmit_timeout: integer(),
            ack_timeout: integer(),
            ack_random_factor: integer() | float(),
            socket_opts: any(),
            error: term() | nil
          }

    @doc false
    # Initialize state with given arguments
    def init(peer, client, args) do
      args = Enum.into(args, %{})

      %__MODULE__{peer: peer, client: client}
      |> init_state(args)
      |> when_valid?(&fill_retransmit_timeout/1)
      |> when_valid?(&validate_ack_random_factor/1)
    end

    @doc false
    def reset(%__MODULE__{} = s) do
      fill_retransmit_timeout(%{s | retries: 0})
    end

    @doc false
    def when_valid?(%__MODULE__{error: nil} = state, fun),
      do: fun.(state)

    @doc false
    def when_valid?(s, _), do: s

    @doc false
    def default_ack_random_factor, do: @ack_random_factor

    defp init_state(s, args) do
      options =
        args
        |> Map.take([
          :ack_timeout,
          :ack_random_factor,
          :max_retransmit,
          :socket_opts,
          :socket_adapter
        ])

      s
      |> Map.merge(options, fn
        _key, v1, nil -> v1
        _key, _v1, v2 -> v2
      end)
    end

    defp validate_ack_random_factor(%{ack_random_factor: factor} = s)
         when is_float(factor) and factor >= 1.0,
         do: s

    defp validate_ack_random_factor(s),
      do: %{s | error: {:badarg, :ack_random_factor, s.ack_random_factor}}

    defp fill_retransmit_timeout(s) do
      %{
        s
        | retransmit_timeout: __retransmit_timeout__(s.ack_timeout, s.ack_random_factor)
      }
    end

    def __max_transmit_wait__(
          ack_timeout,
          max_retransmit,
          ack_random_factor \\ State.default_ack_random_factor()
        ) do
      round(ack_timeout * (:math.pow(2, max_retransmit + 1) - 1) * ack_random_factor)
    end

    def __retransmit_timeout__(
          ack_timeout,
          ack_random_factor \\ State.default_ack_random_factor()
        ) do
      random = :rand.uniform() * ack_timeout * (ack_random_factor - 1)
      round(ack_timeout + random)
    end
  end

  # Socket implementation is not linked to transport process, but monitored
  @callback start(peer(), transport(), socket_opts()) :: GenServer.on_start()

  @doc false
  @spec start_link(peer(), client(), args()) :: GenStateMachine.on_start()
  def start_link(peer, client, args) do
    GenStateMachine.start_link(__MODULE__, {peer, client, args})
  end

  @doc false
  @spec start(peer(), client(), args()) :: GenStateMachine.on_start()
  def start(peer, client, args) do
    GenStateMachine.start(__MODULE__, {peer, client, args})
  end

  @doc false
  def stop(pid, reason \\ :normal), do: GenStateMachine.stop(pid, reason)

  @impl GenStateMachine
  def init({peer, client, args}) do
    peer
    |> State.init(client, args)
    |> State.when_valid?(&open_socket/1)
    |> case do
      %State{error: nil} = s -> {:ok, :closed, s}
      %State{error: reason} -> {:stop, reason}
    end
  end

  @impl GenStateMachine
  # For tests/debugging purpose
  def handle_event(:info, :reset, _, s),
    do: {:next_state, :closed, State.reset(s)}

  def handle_event({:call, from}, :state_name, state_name, _s),
    do: {:keep_state_and_data, {:reply, from, state_name}}

  #
  # STATE: _any
  #

  # Socket closed
  def handle_event(
        :info,
        {:DOWN, ref, :process, _socket, _reason},
        _state_name,
        %State{socket_ref: ref} = s
      ) do
    s
    |> open_socket()
    |> case do
      %State{error: nil} -> {:keep_state, s}
      %State{error: reason} -> {:stop, {:socket, reason}, %{s | socket: nil}}
    end
  end

  def handle_event(:info, {:DOWN, _, _, _, _}, _, _s),
    do: :keep_state_and_data

  #
  # STATE: :closed
  #

  # M_CMD[reliable_send]
  def handle_event(:info, %Message{type: :con, message_id: mid} = m, :closed, s) do
    tx_socket(s, m)
    {:next_state, {:reliable_tx, mid}, s, {:state_timeout, s.retransmit_timeout, m}}
  end

  # M_CMD[unreliable_send]
  def handle_event(:info, %Message{type: :non} = m, :closed, s) do
    tx_socket(s, m)
    :keep_state_and_data
  end

  # RX_CON
  def handle_event(:info, {:recv, %Message{type: :con, message_id: mid} = m, from}, :closed, s) do
    request_response_event(s, {:rr_rx, m, from})
    # No timeout, but RR layer should take care of ack'ing message in a
    # reasonble time
    {:next_state, {:ack_pending, mid}, s}
  end

  # RX_NON
  def handle_event(:info, {:recv, %Message{type: :non} = m, from}, :closed, s) do
    request_response_event(s, {:rr_rx, m, from})
    :keep_state_and_data
  end

  # RX_ACK
  def handle_event(:info, {:recv, %Message{type: :ack}, _from}, :closed, _s),
    do: :keep_state_and_data

  # RX_RST
  def handle_event(:info, {:recv, %Message{type: :reset} = m, from}, :closed, s) do
    request_response_event(s, {:rr_rx, m, from})
    :keep_state_and_data
  end

  #
  # STATE: {:reliable_tx, message_id}
  #

  # M_CMD[cancel]
  def handle_event(:info, {:cancel, mid}, {:reliable_tx, mid}, s),
    do: {:next_state, :closed, s}

  # M_CMD[reliable_send] - non matching
  def handle_event(:info, %Message{type: :con}, {:reliable_tx, _id}, _s) do
    {:keep_state_and_data, :postpone}
  end

  # RX_ACK
  def handle_event(
        :info,
        {:recv, %Message{type: :ack, message_id: mid} = m, from},
        {:reliable_tx, mid},
        s
      ) do
    request_response_event(s, {:rr_rx, m, from})
    {:next_state, :closed, s}
  end

  # RX_RST
  def handle_event(
        :info,
        {:recv, %Message{type: :reset, message_id: mid}, _from},
        {:reliable_tx, mid},
        s
      ) do
    request_response_event(s, {:rr_fail, mid, :reset})
    {:next_state, :closed, s}
  end

  # RX_NON
  def handle_event(
        :info,
        {:recv, %Message{type: :non, message_id: mid} = m, from},
        {:reliable_tx, mid},
        s
      ) do
    request_response_event(s, {:rr_rx, m, from})
    {:next_state, :closed, s}
  end

  # RX_CON
  def handle_event(
        :info,
        {:recv, %Message{type: :con, message_id: mid} = m, from},
        {:reliable_tx, mid},
        s
      ) do
    request_response_event(s, {:rr_rx, m, from})
    {:next_state, {:ack_pending, mid}, s}
  end

  # RX_* - non-matching id
  def handle_event(:info, {:recv, _m, _from}, {:reliable_tx, _mid}, _s) do
    {:keep_state_and_data, :postpone}
  end

  # TIMEOUT[RETX_TIMEOUT] - max_retransmit reached
  def handle_event(
        :state_timeout,
        %Message{type: :con, message_id: mid},
        {:reliable_tx, mid},
        %State{
          retries: max_retransmit,
          max_retransmit: max_retransmit
        } = s
      ) do
    request_response_event(s, {:rr_fail, mid, :timeout})
    {:next_state, :closed, s}
  end

  # TIMEOUT[RETX_TIMEOUT] - max_retransmit not reached
  def handle_event(
        :state_timeout,
        %Message{type: :con, message_id: mid} = m,
        {:reliable_tx, mid},
        s
      ) do
    tx_socket(s, m)
    s = %{s | retransmit_timeout: s.retransmit_timeout * 2, retries: s.retries + 1}
    {:keep_state, s, {:state_timeout, s.retransmit_timeout, m}}
  end

  #
  # STATE: :ack_pending
  #

  # M_CMD[ACK]
  def handle_event(:info, %Message{type: :ack, message_id: mid} = m, {:ack_pending, mid}, s) do
    tx_socket(s, m)
    {:next_state, :closed, s}
  end

  # M_CMD[*]
  def handle_event(:info, %Message{}, {:ack_pending, _}, _s),
    do: {:keep_state_and_data, :postpone}

  @impl GenStateMachine
  def terminate(_reason, _state, %{socket: nil}),
    do: :ok

  def terminate(_reason, _state, s) do
    send(s.socket, :close)
  end

  ###
  ### Priv
  ###
  defp open_socket(%{socket_adapter: adapter, peer: peer, socket_opts: opts} = s) do
    case apply(adapter, :start, [peer, self(), opts]) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{s | socket: pid, socket_ref: ref}

      {:error, reason} ->
        %{s | error: reason}
    end
  end

  defp tx_socket(%State{socket: socket}, m) do
    send(socket, {:send, m})
  end

  defp request_response_event(%State{client: client}, evt) do
    send(client, evt)
  end
end
