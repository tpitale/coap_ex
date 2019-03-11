defmodule CoAP.Connection do
  @moduledoc """
    Maintains a connection to a peer
    Either as a server for each connection id {id,port,token} from a socket_server
    Or as a client

    Phases:
    ----------------------------------------------------------------------------
    | Server
    |---------------------------------------------------------------------------
    | idle -> [awaiting_app_ack,got_non,got_reset]
    | awaiting_app_ack -> [peer_ack_sent]
    | got_non -> ?
    | peer_ack_sent -> ?
    | got_reset -> ?
    ----------------------------------------------------------------------------
    ----------------------------------------------------------------------------
    | Client
    |---------------------------------------------------------------------------
    | idle -> [sent_non,awaiting_peer_ack]
    | sent_non -> [got_reset]
    | awaiting_peer_ack -> [app_ack_sent,got_reset]
    | app_ack_sent -> ?
    | got_reset -> ?
    ----------------------------------------------------------------------------
  """

  use GenServer

  defmodule State do
    @max_retries 4

    # udp socket
    defstruct server: nil,
              # App
              handler: nil,
              # peer ip
              ip: nil,
              # peer port
              port: nil,
              # connection token
              token: nil,
              phase: :idle,
              message: <<>>,
              timer: nil,
              retries: @max_retries,
              retry_timeout: 0,
              in_payload: CoAP.Payload.empty(),
              next_message_id: nil
  end

  # use CoAP.Transport
  # use CoAP.Responder

  import Logger, only: [info: 1, debug: 1]

  alias CoAP.Message
  alias CoAP.Payload
  # alias CoAP.Multipart
  # alias CoAP.Block

  # @ack_timeout 2000
  # ack_timeout*0.5
  # @ack_random_factor 1000

  # standard allows 2000
  @processing_delay 1000
  # @connection_timeout 247_000
  # @non_timeout 145_000

  # 16 bit number
  @max_message_id 65535

  def child_spec(server, endpoint, peer) do
    %{
      id: peer,
      start: {__MODULE__, :start_link, [server, endpoint, peer]},
      restart: :transient,
      modules: [__MODULE__]
    }
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  # TODO: predefined defaults, merged with client/server-specific options
  # TODO: default adapter to GenericServer?
  def init([server, {adapter, endpoint}, {ip, port, token} = _peer]) do
    {:ok, handler} = start_handler(adapter, endpoint)

    {:ok,
     %State{
       server: server,
       handler: handler,
       ip: ip,
       port: port,
       token: token
     }}
  end

  # Non-adapted endpoint, e.g., client
  # def init([server, endpoint, {ip, port, token} = _peer]) do
  # end

  def init([client, {ip, port, token} = peer]) do
    # TODO: make a new socket server with DynamicSupervisor
    # client is the endpoint
    # peer is the target ip/port?
    endpoint = {CoAP.Adapters.Client, client}

    {:ok, server} = start_socket_for(endpoint, peer)
    {:ok, handler} = start_handler(endpoint)

    {:ok,
     %State{
       server: server,
       handler: handler,
       ip: ip,
       port: port,
       token: token,
       next_message_id: next_message_id()
     }}
  end

  # Block1 option is for requests
  # Block2 option is for responses

  def handle_info({:receive, %Message{} = message}, state) do
    # TODO: connection timeouts
    # TODO: start timer for conn

    message
    |> receive_message(state)
    |> state_for_return()
  end

  def handle_info({:deliver, %Message{} = message}, state) do
    message
    |> deliver_message(state)
    |> state_for_return()
  end

  def handle_info(:timeout, state) do
    timeout(state)
    |> state_for_return()
  end

  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}

  # TODO: connection timeout, set to original state?

  # def handle_info(:retry, state)

  # def handle_info({:send, data}, state) do
  # end

  # RECEIVE ====================================================================
  # con -> reset
  # TODO: how do we get a nil method, vs a response
  # defp receive_message(%Message{method: nil, type: :con} = message, %{phase: :idle} = state) do
  # TODO: peer ack with reset, next state is peer_ack_sent
  # Message.response_for(message)
  # reply(:reset, message, state[:server])
  # end

  # TODO: resend reset?
  defp receive_message(_message, %{phase: :peer_ack_sent} = state), do: state

  # Do nothing if we receive a message from peer during these states; we should be shutting down
  defp receive_message(_message, %{phase: :awaiting_app_ack} = state), do: state
  defp receive_message(_message, %{phase: :got_reset} = state), do: state

  # We should never reach here, the connection should be stopped
  defp receive_message(_message, %{phase: :app_ack_sent} = state), do: state
  defp receive_message(_message, %{phase: :sent_non} = state), do: state
  defp receive_message(_message, %{phase: :got_non} = state), do: state

  # BLOCK-WISE TRANSFER
  defp receive_message(%{multipart: %{more: true}} = message, state) do
    reply(Message.response_for({:ok, :continue}, message), state)

    # TODO: do we care about size?
    # TODO: what do we want to do with control

    %{
      state
      | in_payload: Payload.add(state[:in_payload], message.multipart.number, message.payload)
    }
  end

  defp receive_message(%{multipart: %{more: false}} = message, state) do
    %{
      message
      | payload: Payload.to_binary(state[:in_payload]),
        options: %{message.options | block1: nil, block2: nil},
        multipart: nil
    }
    |> receive_message(state)

    %{state | in_payload: nil}
  end

  # con, method, request (server)
  # con, response (client)
  defp receive_message(%Message{type: :con} = message, %{phase: :idle} = state) do
    handle(message, state[:handler], peer_for(state))

    await_app_ack(message, state)
  end

  # non, method, request (server)
  # non, response (client)
  defp receive_message(%Message{type: :non} = message, %{phase: :idle} = state) do
    handle(message, state[:handler], peer_for(state))

    %{state | phase: next_phase(:idle, :non, :in)}
  end

  # phase is :sent_non or :awaiting_peer_ack
  defp receive_message(%Message{type: :reset} = _message, %{phase: phase} = state) do
    cancel_timer(state.timer)

    send(state[:handler], :error)

    %{state | phase: next_phase(phase, :reset), timer: nil}
  end

  # ACK (as server, from client)
  # Response (as client, from server) message
  defp receive_message(message, %{phase: :awaiting_peer_ack} = state) do
    cancel_timer(state.timer)

    handle(message, state[:handler], peer_for(state))

    %{state | phase: next_phase(:awaiting_peer_ack, nil), timer: nil}
  end

  # defp receive_message(message, %{phase: :awaiting_peer_ack} = state) do
  #   handle(:response, message, state[:handler], peer_for(state))
  #
  #   app_ack_sent(state)
  # end

  # TODO: receive_message(:error) from decoding error

  # DELIVER ====================================================================
  # reply from app to peer
  defp deliver_message(message, %{phase: :awaiting_app_ack} = state) do
    send_peer_ack(message, state)
  end

  # send message to peer from client
  defp deliver_message(
         %Message{type: type} = message,
         %{phase: :idle, next_message_id: message_id} = state
       ) do
    %{message | message_id: message_id}
    |> reply(state)

    %{
      state
      | phase: next_phase(:idle, type, :out),
        message: if(type == :con, do: message, else: nil),
        next_message_id: next_message_id(message_id)
    }
  end

  # TIMEOUTS ===================================================================
  defp timeout(%{phase: :awaiting_app_ack, message: message} = state) do
    # send stored message
    reply(message, state)

    %{state | phase: next_phase(:awaiting_app_ack, nil)}
  end

  defp timeout(%{phase: :awaiting_peer_ack, retries: 0} = state) do
    # TODO: send error back to handler?
    %{state | timer: nil}
  end

  defp timeout(
         %{
           phase: :awaiting_peer_ack,
           message: message,
           retry_timeout: timeout,
           retries: retries
         } = state
       ) do
    reply(message, state)

    timeout = timeout * 2
    timer = start_timer(timeout)

    %{
      state
      | phase: :awaiting_peer_ack,
        timer: timer,
        retry_timeout: timeout,
        retries: retries - 1
    }
  end

  defp timeout(state) do
    info("Received timeout: #{inspect(state)}")
    state
  end

  # STATE TRANSITIONS ==========================================================
  defp await_app_ack(message, state) do
    # ready for APP timeout
    cached_response = Message.response_for(message)
    timer = restart_timer(state[:timer], @processing_delay)

    %{state | phase: :awaiting_app_ack, message: cached_response, timer: timer}
  end

  defp send_peer_ack(message, state) do
    cancel_timer(state.timer)

    response =
      Message.response_for(
        {message.code_class, message.code_detail},
        message.payload,
        message
      )

    debug("Sending response: #{inspect(response)}")

    reply(response, state)

    %{state | phase: :peer_ack_sent, message: response, timer: nil}
  end

  # phase, type
  defp next_phase(_phase, :reset), do: :got_reset
  defp next_phase(:awaiting_peer_ack, _), do: :app_ack_sent
  defp next_phase(:awaiting_app_ack, nil), do: :peer_ack_sent
  defp next_phase(:idle, :con, :out), do: :awaiting_peer_ack
  defp next_phase(:idle, :non, :out), do: :sent_non
  defp next_phase(:idle, :non, :in), do: :got_non

  # REQUEST ====================================================================
  defp handle(message, handler, peer) do
    send(handler, {direction(message), message, peer, self()})
  end

  # RESPOND ====================================================================
  defp reply(message, %{server: server} = state) do
    send(server, {:deliver, message, peer_for(state)})
  end

  # HELPERS ====================================================================
  defp state_for_return(%{phase: :sent_non} = state), do: {:stop, :normal, state}
  defp state_for_return(%{phase: :got_non} = state), do: {:stop, :normal, state}
  defp state_for_return(%{phase: :app_ack_sent} = state), do: {:stop, :normal, state}
  defp state_for_return(%{phase: :peer_ack_sent} = state), do: {:stop, :normal, state}
  defp state_for_return(state), do: {:noreply, state}

  defp direction(%{type: :ack}), do: :ack
  defp direction(%{method: nil}), do: :response
  defp direction(%{method: m}) when is_atom(m), do: :request

  defp peer_for(%{ip: ip, port: port}), do: {ip, port}

  # TIMERS =====================================================================
  defp start_timer(timeout, key \\ :timeout), do: Process.send_after(self(), key, timeout)

  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp restart_timer(nil, timeout), do: start_timer(timeout)

  defp restart_timer(timer, timeout) do
    cancel_timer(timer)

    start_timer(timeout)
  end

  defp next_message_id() do
    :rand.seed(:exs1024)
    :rand.uniform(@max_message_id)
  end

  defp next_message_id(id) when is_integer(id) do
    if id < @max_message_id, do: id + 1, else: 1
  end

  # HANDLER
  # TODO: move to CoAP
  defp start_handler({adapter, endpoint}), do: start_handler(adapter, endpoint)

  defp start_handler(adapter, endpoint) do
    DynamicSupervisor.start_child(
      CoAP.HandlerSupervisor,
      {
        CoAP.Handler,
        [adapter, endpoint]
      }
    )
  end

  # TODO: move to CoAP
  defp start_socket_for(endpoint, peer) do
    DynamicSupervisor.start_child(
      CoAP.SocketServerSupervisor,
      {
        CoAP.SocketServer,
        [endpoint, peer, self()]
      }
    )
  end
end
