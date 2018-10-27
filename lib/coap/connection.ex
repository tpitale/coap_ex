defmodule CoAP.Connection do
  use GenServer

  # use CoAP.Transport
  # use CoAP.Responder

  import Logger, only: [info: 1]

  alias CoAP.Message

  # @ack_timeout 2000
  # ack_timeout*0.5
  # @ack_random_factor 1000
  @max_retries 4

  # standard allows 2000
  @processing_delay 1000
  # @connection_timeout 247_000
  # @non_timeout 145_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init([server, {adapter, endpoint}, {ip, port, token} = _peer]) do
    {:ok, handler} = start_handler(adapter, endpoint)

    {:ok,
     %{
       # udp socket
       server: server,
       # App
       handler: handler,
       # peer ip
       ip: ip,
       # peer port
       port: port,
       # connection token
       token: token,
       phase: :idle,
       # message sent at timeout
       message: <<>>,
       # timer handling timeout
       timer: nil,
       retries: @max_retries,
       retry_timeout: 0
     }}
  end

  # Non-adapted endpoint, e.g., client
  # def init([server, endpoint, {ip, port, token} = _peer]) do
  # end

  # def init(client) do
  #   # TODO: make a new socket server with DynamicSupervisor
  #   # client is the endpoint
  #   # peer is the target ip/port?
  #   {:ok, %{handler: start_handler(client)}}
  # end

  def handle_info({:receive, %Message{} = message}, state) do
    # TODO: connection timeouts
    # TODO: start timer for conn

    message
    |> receive_message(state)
    |> update_state_for_return(:noreply)
  end

  def handle_info({:deliver, %Message{} = message}, state) do
    message
    |> deliver_message(state)
    |> update_state_for_return(:noreply)
  end

  def handle_info(:timeout, state) do
    timeout(state)
    |> update_state_for_return(:noreply)
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

  # con, request (server)
  defp receive_message(%Message{method: method, type: :con} = message, %{phase: :idle} = state)
       when is_atom(method) do
    handle_request(message, state[:handler], peer_for(state))
    await_app_ack(message, state)
  end

  # con, response (client)
  defp receive_message(%Message{type: :con} = message, %{phase: :idle} = state) do
    handle_response(message, state[:handler], peer_for(state))
    await_app_ack(message, state)
  end

  defp receive_message(%Message{type: :reset} = message, %{phase: :sent_non} = state) do
    handle_error(message, state[:handler], peer_for(state))

    %{state | phase: :got_reset}
  end

  defp receive_message(%Message{type: :ack} = message, %{phase: :awaiting_peer_ack} = state) do
    handle_ack(message, state[:handler], peer_for(state))

    %{state | phase: :app_ack_sent}
  end

  defp receive_message(%Message{type: :reset} = message, %{phase: :awaiting_peer_ack} = state) do
    handle_error(message, state[:handler], peer_for(state))

    %{state | phase: :app_ack_sent}
  end

  defp receive_message(message, %{phase: :awaiting_peer_ack} = state) do
    handle_response(message, state[:handler], peer_for(state))

    %{state | phase: :app_ack_sent}
  end

  defp receive_message(_message, %{phase: :awaiting_app_ack} = state), do: state
  defp receive_message(_message, %{phase: :app_ack_sent} = state), do: state
  defp receive_message(_message, %{phase: :got_reset} = state), do: state

  # TODO: receive_message(:error) from decoding error

  # non, request (server)
  defp receive_message(%Message{method: method, type: :non} = message, state)
       when is_atom(method) do
    handle_request(message, state[:handler], peer_for(state))

    %{state | phase: :got_non}
  end

  # non, response (client)
  defp receive_message(%Message{type: :non} = message, state) do
    handle_response(message, state[:handler], peer_for(state))

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
    send_peer_ack(message, state)
  end

  # TIMEOUTS ===================================================================
  defp timeout(%{phase: :awaiting_app_ack, message: message} = state) do
    # send stored message
    reply(message, state)

    %{state | phase: :peer_ack_sent}
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
    response =
      Message.response_for({message.code_class, message.code_detail}, message.payload, message)

    info("Sending response: #{inspect(response)}")

    reply(response, state)

    %{state | phase: :peer_ack_sent, message: response, timer: nil}
  end

  # REQUEST ====================================================================
  defp handle_request(message, handler, peer) do
    # call the handler with the message and self()
    send(handler, {:request, message, peer, self()})
  end

  # RESPONSE ===================================================================
  defp handle_response(message, handler, peer) do
    # call the handler with the message and self()
    send(handler, {:response, message, peer, self()})
  end

  defp handle_ack(_message, handler, _peer) do
    send(handler, :ack)
  end

  defp handle_error(_message, handler, _peer) do
    send(handler, :error)
  end

  defp reply(message, %{server: server} = state) do
    send(server, {:deliver, peer_for(state), message})
  end

  defp update_state_for_return(state, status), do: {status, state}

  defp peer_for(%{ip: ip, port: port}), do: {ip, port}

  # TIMERS =====================================================================
  defp start_timer(timeout, key \\ :timeout), do: Process.send_after(self(), key, timeout)

  defp restart_timer(nil, timeout), do: start_timer(timeout)

  defp restart_timer(timer, timeout) do
    Process.cancel_timer(timer)

    start_timer(timeout)
  end

  # HANDLER
  defp start_handler(adapter, endpoint) do
    DynamicSupervisor.start_child(
      CoAP.HandlerSupervisor,
      {
        CoAP.Handler,
        [adapter, endpoint]
      }
    )
  end
end
