defmodule CoAP.Connection do
  use GenServer

  # use CoAP.Transport
  # use CoAP.Responder

  alias CoAP.Message

  @ack_timeout 2000
  @ack_random_factor 1000 # ack_timeout*0.5
  @max_retries 4

  @processing_delay 1000 # standard allows 2000
  @connection_timeout 247000
  @non_timeout 145000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(client) do
    # TODO: make a new socket server with DynamicSupervisor
    # client is the handler
    # peer is the target ip/port?
    {:ok, %{handler: client}}
  end

  def init(server, handler, {ip, port, token} = _peer) do
    {:ok, %{
      server: server, # udp socket
      handler: handler, # App
      ip: ip, # peer ip
      port: port, # peer port
      token: token, # connection token
      phase: :idle,
      message: <<>>, # message sent at timeout
      timer: nil, # timer handling timeout
      retries: 0,
      retry_timeout: 0
    }}
  end

  # TODO: connection timeouts

  def handle_info({:receive, data}, state) when is_binary(data) do
    # TODO: based on the type of the message coming in
    # we have to handle it in different ways
    # 1. con -> ack|reset, handle the data
    # 2. ack|reset, change the state of the connection
    # Also depends on the current state of the connection
    # 1. idle, can accept anything/waiting for reply

    # handler.call(Message.decode(data))
    # GenServer.call(handler, {:something, Message.decode(data)})

    # TODO: start timer for conn

    data
    |> Message.decode()
    |> receive_message(state)
    |> update_state_for_return(:noreply)
  end

  def handle_info({:deliver, %Message{} = message}, state) do
    # deliver_message(message, state)
    # |> update_state_for_return(:noreply)
  end

  def handle_info(:timeout, state) do
    timeout(state)
    |> update_state_for_return(:noreply)
  end

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

  # con, request (server)
  defp receive_message(%Message{method: method, type: :con} = message, %{phase: :idle} = state) when is_atom(method) do
    handle_request(message, state)
    await_app_ack(message, state)
  end
  # con, response (client)
  defp receive_message(%Message{type: :con} = message, %{phase: :idle} = state) do
    handle_response(message, state)
    await_app_ack(message, state)
  end

  defp receive_message(%Message{type: :reset} = message, %{phase: :sent_non} = state) do
    handle_error(message, state)

    %{state | phase: :got_reset}
  end

  defp receive_message(%Message{type: :ack} = message, %{phase: :awaiting_peer_ack} = state) do
    handle_ack(message, state)

    %{state | phase: :app_ack_sent}
  end

  defp receive_message(%Message{type: :reset} = message, %{phase: :awaiting_peer_ack} = state) do
    handle_error(message, state)

    %{state | phase: :app_ack_sent}
  end

  defp receive_message(message, %{phase: :awaiting_peer_ack} = state) do
    handle_response(message, state)

    %{state | phase: :app_ack_sent}
  end

  defp receive_message(_message, %{phase: :awaiting_app_ack} = state), do: state
  defp receive_message(_message, %{phase: :app_ack_sent} = state), do: state
  defp receive_message(_message, %{phase: :got_reset} = state), do: state

  # TODO: receive_message(:error) from decoding error

  # non, request (server)
  defp receive_message(%Message{method: method, type: :non} = message, state) when is_atom(method) do
    handle_request(message, state)

    %{state | phase: :got_non}
  end
  # non, response (client)
  defp receive_message(%Message{type: :non} = message, state) do
    handle_response(message, state)

    %{state | phase: :got_non}
  end

  # DELIVER ====================================================================
  defp deliver_message(%Message{type: :non} = message, %{phase: :idle} = state) do
    # deliver message from client
    reply(message, state)

    %{state | phase: :sent_non}
  end
  defp deliver_message(%Message{type: :con} = message, %{phase: :idle} = state) do
    # deliver message from client
    reply(message, state)

    %{state | phase: :awaiting_peer_ack, message: message}
  end
  defp deliver_message(message, %{phase: :awaiting_app_ack} = state) do
    # build & send ack
    %{state | phase: :peer_ack_sent}
  end

  # TIMEOUTS ===================================================================
  defp timeout(%{phase: :awaiting_app_ack, message: message}) do
    # send stored message
    reply(message, state)

    %{state | phase: :peer_ack_sent}
  end
  defp timeout(%{phase: :awaiting_peer_ack, message: message}) do
    # retry send stored message
    reply(message, state)

    # increase timer to X*2
    timer = start_timer(1000)
    # until conn timeout, limit to retries?
    # -> awaiting_peer_ack
    %{state | phase: :awaiting_peer_ack, timer: }
  end

  # STATE TRANSITIONS ==========================================================
  defp await_app_ack(message, state) do
    cached_response = Message.response_for(message) # ready for APP timeout
    timer = restart_timeout(state[:timer], timeout)

    %{state | phase: :awaiting_app_ack, message: cached_response, timer: timer}
  end

  defp send_peer_ack(message, state) do
    #
    # timer =

    %{state | phase: :peer_ack_sent, message: message, timer: nil}
  end

  # REQUEST ====================================================================
  defp handle_request(message, state) do
    # call the handler with the message and self()
  end

  # RESPONSE ===================================================================
  defp handle_response(message, state) do
    # call the handler with the message and self()
  end

  defp handle_ack(message, state) do
  end

  defp handle_error(message, state) do
  end

  defp reply(_message, _state) do
    # encode and send to server socket?
  end

  defp update_state_for_return(state, status), do: {status, state}

  # TIMERS =====================================================================
  defp start_timer(timeout, signal // :timeout), do: send_after(timeout, self(), signal)

  defp restart_timer(nil, timeout), do: start_timer(timeout)
  defp restart_timer(timer, timeout) do
    cancel_timer(timer)

    start_timer(timeout)
  end
end
