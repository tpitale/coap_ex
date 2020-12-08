defmodule CoAP.Connection do
  @moduledoc """
    CoAP.Connection is the bridge between a local `app` (either a `CoAP.Client` or a server)
    and the `peer` socket for a remote CoAP client or server.

    This process maintains the state for the connection and handles passing
    messages between `app` and `peer`.

    Either as a server for each connection id {id,port,token} from a socket_server
    Or as a client.

    A connection should not be started directly, it will be started as necessary
    by a socket_server and managed through that process.

    A connection handles 3 public messages: `deliver`, `receive`, and `timeout`.
    A timeout is received from the timers we set during different phases.

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

    Message Types:
    * con - confirmable, should receive an ack from the peer
    * non - nonconfirmable, a fire and forget message
    * ack - acknowledge a con
    * rst - reset

    Truisms:
      * client always makes requests
      * client receive_message is a response
      * client deliver_message is a request
      * client receives status
      * client delivers verb
      * receive + status => client
      * deliver + verb => client
      * server always makes responses
      * server receive message is a request
      * server deliver_message is a response
      * server receives verb
      * server delivers status
      * deliver + status => server
      * receive + verb => server

    A new connection always begins in the `:idle` phase. When any message
    is received (from peer) or sent (`delivered` from the app), the connection
    starts moving through phases and keeps an appropriate timeout.

    When an a message is received and passed to the `app`, a timer is started for
    the app/server to reply. If not, a canned response is sent and the peer will
    have to make a followup request for the full response from the app.

    When a message is delivered to the peer a timer is started for the peer to ack.
    If an ack is not received, the message delivery is retried up to a point.

    Block-wise transfers, aka Multipart in `coap_ex`, complicates the message
    phase by effectively stalling it while N messages are received/delivered for
    each block of a payload. The payload is maintained as in or out within the
    process state. Once the final message is delivered or received, the assembled
    payload is passed with the original message through the normal phases of the
    connection.
  """

  use GenServer

  defmodule State do
    # 2s is the spec default
    @ack_timeout 2000
    # 1.5 is the spec default
    # gen_coap uses ack_timeout*0.5
    @ack_random_factor 1500

    # standard allows 2000
    @processing_delay 1000

    # @connection_timeout 247_000
    # @non_timeout 145_000

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
              retries: 0,
              max_retries: 0,
              retry_timeout: nil,
              in_payload: CoAP.Payload.empty(),
              out_payload: CoAP.Payload.empty(),
              next_message_id: nil,
              ack_timeout: @ack_timeout,
              processing_delay: @processing_delay,
              tag: nil

    # Used by client
    def add_options(state, options) do
      %{
        state
        | retries: options.retries,
          max_retries: options.retries,
          retry_timeout: options.retry_timeout,
          ack_timeout: options.ack_timeout || @ack_timeout,
          tag: options.tag
      }
    end

    # Used by server
    def add_config(state, options) do
      %{
        state
        | ack_timeout: options[:ack_timeout] || @ack_timeout,
          processing_delay: options[:processing_delay] || @processing_delay
      }
    end

    def ack_timeout(state) do
      state.ack_timeout + :rand.uniform(@ack_random_factor)
    end
  end

  import Logger, only: [info: 1]

  alias CoAP.Message
  alias CoAP.Payload
  alias CoAP.Multipart
  alias CoAP.Block

  @default_payload_size 512

  # 16 bit number
  @max_message_id 65535

  def child_spec([server, endpoint, peer, config]) do
    %{
      id: peer,
      start: {__MODULE__, :start_link, [[server, endpoint, peer, config]]},
      restart: :transient,
      modules: [__MODULE__]
    }
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc """
  `init` functions for Server and Client processes

  For server process:
    `server` is the SocketServer process for the server `app`
    Wrap the adapter (Phoenix or GenericServer) and endpoint (actual "server") in a handler

  For Client process:
    `client`: `CoAP.Client`
    `endpoint`: the wrapped client in an adapter
    `server`: SocketServer started for the endpoint and peer tuple

    Wrap the adapter and the client in a handler
  """
  def init([server, {adapter, endpoint}, {ip, port, token} = _peer, config]) do
    {:ok, handler} = start_handler(adapter, endpoint)

    {:ok,
     %State{
       server: server,
       handler: handler,
       ip: ip,
       port: port,
       token: token
     }
     |> State.add_config(config)}
  end

  def init([client, {ip, port, token} = peer, options]) do
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
     }
     |> State.add_options(options)}
  end

  def handle_info({:receive, %Message{} = message}, state) do
    :telemetry.execute(
      [:coap_ex, :connection, :data_received],
      %{size: message.raw_size},
      %{
        host: state.ip,
        port: state.port,
        message_id: message.message_id,
        token: message.token,
        tag: state.tag
      }
    )

    message
    |> receive_message(state)
    |> reset_retries()
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

  def handle_info({:tag, tag}, state), do: {:noreply, %{state | tag: tag}}

  # _TODO: connection timeout, set to original state?

  # def handle_info(:retry, state)

  # def handle_info({:send, data}, state) do
  # end

  # RECEIVE ====================================================================
  # con -> reset
  # _TODO: how do we get a nil method, vs a response
  # defp receive_message(%Message{method: nil, type: :con} = message, %{phase: :idle} = state) do
  #   _TODO: peer ack with reset, next state is peer_ack_sent
  #   Message.response_for(message)
  #   reply(:reset, message, state[:server])
  # end

  # _TODO: resend reset?
  # _TODO: what is the message if the client has to re-request after a processing timeout from the app?

  # _TODO: resend stored message (ack)
  defp receive_message(_message, %{phase: :peer_ack_sent} = state), do: state

  # Do nothing if we receive a message from peer during these states; we should be shutting down
  defp receive_message(_message, %{phase: :awaiting_app_ack} = state), do: state
  defp receive_message(_message, %{phase: :got_reset} = state), do: state

  # We should never reach here, the connection should be stopped
  defp receive_message(_message, %{phase: :app_ack_sent} = state), do: state
  defp receive_message(_message, %{phase: :sent_non} = state), do: state
  defp receive_message(_message, %{phase: :got_non} = state), do: state

  # BLOCK-WISE TRANSFER: CLIENT REQUEST FOR NEXT BLOCK FROM SERVER
  # Receive a message with a multipart (block-wise transfer component)
  # This message includes a requested_number to return the next block in the full payload
  #
  # 1. restart the timer for ack_timeout from the peer
  # 2. Take the out payload
  # 3. Fetch the next block given the requested_number
  # 4. Build a response, using the same message_id from the request
  # 5. Add the payload bytes for this block
  # 6. Add the description of this block to the message as multipart
  # 7. Send the message back to the client
  # 8. Store the out_payload and cache the response in state
  defp receive_message(
         %{multipart: %{requested_number: number}, message_id: message_id, token: token} =
           _message,
         %{phase: :awaiting_peer_ack, tag: tag} = state
       )
       when number > 0 do
    # Payload should calculate byte offset from next number
    {bytes, block, next_payload} = Payload.segment_at(state.out_payload, number)

    timer =
      case block.more do
        true ->
          restart_timer(state.timer, ack_timeout(state))

        false ->
          # if this is the last block in the transfer don't expect any additional messages
          cancel_timer(state.timer)
      end

    response = %{
      state.message
      | message_id: message_id,
        payload: bytes,
        multipart: Multipart.build(block, nil)
    }

    reply(response, state)

    :telemetry.execute(
      [:coap_ex, :connection, :block_sent],
      %{size: byte_size(bytes), block_number: number, more_blocks: block.more},
      %{
        message_id: message_id,
        token: token,
        block_size: state.out_payload.size,
        total_size: byte_size(state.out_payload.data),
        tag: tag
      }
    )

    %{state | timer: timer, out_payload: next_payload, message: response}
  end

  # BLOCK-WISE TRANSFER:
  #   PUT/POST REQUEST WITH BODY AS SERVER
  #   RESPONSE FROM SERVER AS CLIENT
  # Receive a message from the peer which contains a block of a payload
  #
  # 1. restart the timer for ack_timeout from the peer
  # 2. Build the request for the next blaock
  # 3. Build a response, using the next message_id when we're making a subsequent request as a client
  # 3. As a server, we are receiving a payload, so send a response of {:ok, :continue} to get the next block
  # 4. Add the control for the block we want next to the message as multipart
  # 5. Send the message back to the client
  # 6. Add the block to the in_payload, cache the message and store in state
  defp receive_message(
         %{multipart: %{more: true, number: number, size: size}} = message,
         state
       ) do
    timer = restart_timer(state.timer, ack_timeout(state))

    # _TODO: respect the number/size from control
    # more must be false, must use same size on subsequent request
    multipart = Multipart.build(nil, Block.build({number + 1, false, size}))

    # alternatively message.verb == nil => client
    response =
      case message.status do
        # client sends original message with new control number
        # _TODO: what parts of the message are we supposed to send back?
        {:ok, _} ->
          Message.next_message(state.message, next_message_id(state.message.message_id))

        # server sends ok, continue
        _ ->
          Message.response_for({:ok, :continue}, message)
      end

    response = %{response | multipart: multipart}
    reply(response, state)

    :telemetry.execute(
      [:coap_ex, :connection, :block_received],
      %{size: byte_size(message.payload), block_number: number, more_blocks: true},
      %{
        message_id: message.message_id,
        token: message.token,
        block_size: size,
        tag: state.tag
      }
    )

    %{
      state
      | in_payload: Payload.add(state.in_payload, number, message.payload),
        timer: timer,
        message: response
    }
  end

  # Receive the last block in a multipart transfer
  # Add the block to the in_payload
  # then proceed to receive the message as if it was not multipart
  defp receive_message(
         %{multipart: %{more: false, number: number, size: size}} = message,
         state
       )
       when number > 0 do
    payload =
      state.in_payload
      |> Payload.add(number, message.payload)
      |> Payload.to_binary()

    :telemetry.execute(
      [:coap_ex, :connection, :block_received],
      %{size: byte_size(message.payload), block_number: number, more_blocks: false},
      %{
        message_id: message.message_id,
        token: message.token,
        block_size: size,
        tag: state.tag
      }
    )

    %{
      message
      | payload: payload,
        multipart: nil
    }
    |> receive_message(%{state | in_payload: nil})
  end

  # con, method, request (server)
  # con, status, response (client)
  defp receive_message(%Message{type: :con} = message, %{phase: :idle} = state) do
    handle(message, state.handler, peer_for(state))

    await_app_ack(message, state)
  end

  # non, method, request (server)
  # non, status, response (client)
  defp receive_message(%Message{type: :non} = message, %{phase: :idle} = state) do
    handle(message, state.handler, peer_for(state))

    %{state | phase: next_phase(:idle, :non, :in)}
  end

  # phase is :sent_non or :awaiting_peer_ack
  defp receive_message(%Message{type: :reset} = _message, %{phase: phase} = state) do
    cancel_timer(state.timer)

    send(state.handler, :error)

    %{state | phase: next_phase(phase, :reset), timer: nil}
  end

  # ACK (as server, from client)
  # Response (as client, from server) message
  defp receive_message(message, %{phase: :awaiting_peer_ack} = state) do
    cancel_timer(state.timer)

    # _TODO: what happens if this is an empty ACK and we get another response later?
    # Could we go back to being idle?
    handle(message, state.handler, peer_for(state))

    %{state | phase: next_phase(:awaiting_peer_ack, nil), timer: nil}
  end

  # DELIVER ====================================================================
  # _TODO: deliver message for got_non as a NON message, phase becomes :sent_non
  # _TODO: deliver message for peer_ack_sent as a CON message, phase becomes :awaiting_peer_ack

  defp deliver_message(message, %{phase: :awaiting_app_ack} = state) do
    # _TODO: does the message include the original request control?
    {bytes, block, payload} = Payload.segment_at(message.payload, @default_payload_size, 0)

    # Cancel the app_ack waiting timeout
    cancel_timer(state.timer)

    # _TODO: what happens if the app response is a status code, no code_class/detail tuple?
    response =
      Message.response_for(
        {message.code_class, message.code_detail},
        bytes,
        message
      )

    response = %{response | multipart: Multipart.build(block, nil)}

    reply(response, state)

    phase =
      case payload.multipart do
        true -> :awaiting_peer_ack
        false -> :peer_ack_sent
      end

    %{state | phase: phase, out_payload: payload, message: response, timer: nil}
  end

  # send message to peer from client
  # The client should not send a message id, that is managed by the connection
  defp deliver_message(
         %Message{type: type, message_id: message_id} = message,
         %{phase: :idle, next_message_id: next_message_id} = state
       ) do
    # _TODO: get payload size from the request control
    {bytes, block, payload} = Payload.segment_at(message.payload, @default_payload_size, 0)

    # The server should send back the same message id of the request
    %{
      message
      | message_id: message_id || next_message_id,
        payload: bytes,
        multipart: Multipart.build(block, nil)
    }
    |> reply(state)

    timeout = ack_timeout(state)
    timer = restart_timer(state.timer, timeout)

    %{
      state
      | phase: next_phase(:idle, type, :out),
        message: if(type == :con, do: message, else: nil),
        next_message_id: next_message_id(next_message_id),
        out_payload: payload,
        timer: timer,
        retry_timeout: state.retry_timeout || timeout
    }
  end

  # TIMEOUTS ===================================================================
  defp timeout(%{phase: :awaiting_app_ack, message: message} = state) do
    # send stored message
    reply(message, state)

    %{state | phase: next_phase(:awaiting_app_ack, nil)}
  end

  defp timeout(%{phase: :awaiting_peer_ack, retries: 0} = state) do
    send(state.handler, {:error, {:timeout, state.phase}})

    %{state | timer: nil, phase: next_phase(:awaiting_peer_ack, nil)}
  end

  defp timeout(
         %{
           phase: :awaiting_peer_ack,
           message: message,
           retry_timeout: timeout,
           retries: retries,
           tag: tag
         } = state
       ) do
    # retry delivering the cached message
    reply(message, state)

    remaining = retries - 1

    timeout =
      case remaining do
        0 ->
          # on the last retry, time out and return to the client after ack_timeout
          ack_timeout(state)

        _ ->
          timeout * 2
      end

    timer = start_timer(timeout)

    :telemetry.execute(
      [:coap_ex, :connection, :re_tried],
      %{size: byte_size(message.payload)},
      %{
        message_id: message.message_id,
        token: message.token,
        remaining_retries: remaining,
        tag: tag
      }
    )

    %{
      state
      | phase: :awaiting_peer_ack,
        timer: timer,
        retry_timeout: timeout,
        retries: remaining
    }
  end

  defp timeout(state) do
    info("Received timeout: #{inspect(state)}")

    :telemetry.execute(
      [:coap_ex, :connection, :timed_out],
      %{},
      %{message_id: state.message.message_id, token: state.message.token, tag: state.tag}
    )

    state
  end

  # STATE TRANSITIONS ==========================================================
  defp await_app_ack(message, state) do
    # ready for APP timeout
    cached_response = Message.response_for(message)
    timer = restart_timer(state.timer, processing_delay(state))

    %{state | phase: :awaiting_app_ack, message: cached_response, timer: timer}
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
  defp reply(message, %{server: server, tag: tag} = state) do
    send(server, {:deliver, message, peer_for(state), tag})
  end

  # HELPERS ====================================================================
  defp reset_retries(%{max_retries: retries} = state), do: %{state | retries: retries}

  defp state_for_return(%{phase: :sent_non} = state), do: {:stop, :normal, state}
  defp state_for_return(%{phase: :got_non} = state), do: {:stop, :normal, state}
  defp state_for_return(%{phase: :app_ack_sent} = state), do: {:stop, :normal, state}
  defp state_for_return(%{phase: :peer_ack_sent} = state), do: {:stop, :normal, state}
  defp state_for_return(state), do: {:noreply, state}

  # defp direction(%{type: :ack})
  defp direction(%{method: nil, status: _status}), do: :response
  defp direction(%{method: m}) when is_atom(m), do: :request

  defp peer_for(%{ip: ip, port: port}), do: {ip, port}

  # TIMERS =====================================================================
  defp ack_timeout(state), do: State.ack_timeout(state)
  defp processing_delay(state), do: state.processing_delay

  defp start_timer(timeout, key \\ :timeout), do: Process.send_after(self(), key, timeout)

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end

  defp restart_timer(nil, timeout), do: start_timer(timeout)

  defp restart_timer(timer, timeout) do
    cancel_timer(timer)

    start_timer(timeout)
  end

  defp next_message_id() do
    :rand.seed(:exs1024)
    :rand.uniform(@max_message_id)
  end

  # The server does not need to track message_id, just mirror the request
  defp next_message_id(nil), do: nil

  defp next_message_id(id) when is_integer(id) do
    if id < @max_message_id, do: id + 1, else: 1
  end

  # HANDLER
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
