defmodule CoAP.Transport do
  @moduledoc """
  Send and retries
  """

  # NON and CON->ACK|RST message transmission
  # handles message retransmission and de-duplication
  # -export([init/6, received/2, send/2, timeout/2, awaits_response/1]).
  # -export([idle/2, got_non/2, sent_non/2, got_rst/2, await_ack/2, pack_sent/2, await_pack/2, ack_sent/2]).

  @ack_timeout 2000
  @ack_random_factor 1000 # ack_timeout*0.5
  @max_retransmit 4

  @processing_delay 1000 # standard allows 2000
  @exchange_lifetime 247000
  @non_lifetime 145000

  # -record(state, {phase, sock, cid, channel, tid, resp, receiver, msg, timer, retry_time, retry_count}).

  # -include("coap.hrl")

  def init(socket, channel_id, channel, TrId, ReSup, receiver) do
    #state{phase=idle, sock=socket, cid=channgel_id, channel=channel, tid=TrId, resp=ReSup, receiver=receiver}
    %{phase: :idle, socket: socket, channel_id: channel_id, channel: channel, receiver: receiver}
  end

  # process incoming message
  def received(message, %{phase: phase} = state) do
    apply(__MODULE__, phase, [{:in, message}, state])
  end

  # process outgoing message
  def send(message, %{phase: phase} = state) do
    apply(__MODULE__, phase, [{:out, message}, state])
  end

  # when the transport expires remove terminate the state
  def timeout(:transport, _state) do
    nil
  end

  # process timeout
  def timeout(event, %{phase: phase} = state) do
    apply(__MODULE__, phase, [{:timeout, event}, state])
  end

  # check if we can send a response
  def awaits_response(%{phase: :await_ack}), do: true
  def awaits_response(_state), do: false

  # ->NON
  def idle(message={:in, <<1::size(2), 1::size(2), _::size(12), _tail::binary>>}, %{channel: channel, tid: TrId} = state) do
    timeout_after(@non_lifetime, channel, TrId, transport),
    in_non(message, state)
  end

  # ->CON
  def idle(message={:in, <<1::size(2), 0::size(2), _::size(12), _tail::binary>>}, %{channel: channel, tid: TrId} = state) do
    timeout_after(@exchange_lifetime, channel, TrId, transport),
    in_con(message, state)
  end

  # NON->
  def idle(message={:out, %CoAP.message{type: :non}}, %{channel: channel, tid: TrId} = state) do
    timeout_after(@non_lifetime, channel, TrId, transport),
    out_non(message, state)
  end

  # CON->
  def idle(message={:out, %CoAP.message{type: :con}}, %{channel: channel, tid: TrId} = state) do
    timeout_after(@exchange_lifetime, channel, TrId, transport),
    out_con(message, state)
  end

  # --- incoming NON

  def in_non({:in, message}, state) do
    case catch CoAP.Message.decode(message) do
      %CoAP.Message{method: method} = message when is_atom(method) ->
        handle_request(message, state);
      %CoAP.Message{} = message ->
        handle_response(message, state);
      {error, _error} ->
        # shall we sent reset back?
        :ok
    end
    next_state(:got_non, state)
  end

  def got_non({:in, _message}, state) do
    # ignore request retransmission
    next_state(:got_non, state)
  end

  # --- outgoing NON

  def out_non({out, message}, %{socket: socket, channel_id: channel_id} = state) do
    IO.inspect("~p <= ~p~n", [self(), message])
    binary_message = CoAP.Message.encode(message)
    Sock ! {datagram, channel_id, binary_message}
    next_state(sent_non, state)
  end

  # we may get reset
  def sent_non({in, binary_message}, State) do
      case catch coap_message_parser:decode(binary_message) of
          %CoAP.Message{type=reset} = message ->
              handle_error(message, reset, State)
      end,
      next_state(got_rst, State).

  def got_rst({in, _binary_message}, State) do
      next_state(got_rst, State).

  # --- incoming CON->ACK|RST

  def in_con({in, binary_message}, State) do
      case catch coap_message_parser:decode(binary_message) of
          %CoAP.Message{method=nil, id=MsgId} ->
              # provoked reset
              go_pack_sent(%CoAP.Message{type=reset, id=MsgId}, State);
          %CoAP.Message{method=Method} = message when is_atom(Method) ->
              handle_request(message, State),
              go_await_ack(message, State);
          %CoAP.Message{} = message ->
              handle_response(message, State),
              go_await_ack(message, State);
          {error, Error} ->
              go_pack_sent(%CoAP.Message{type=ack, method={error, bad_request},
                                         id=coap_message_parser:message_id(binary_message),
                                         payload=list_to_binary(Error)}, State)
      end.

  def go_await_ack(message, state) do
    # we may need to ack the message
    binary_ack = CoAP.Message.encode(coap_message:response(message))
    next_state(await_ack, %{state | message: bin_ack}, @processing_delay)
  end

  def await_ack({:in, _binary_message}, state) do
    # ignore request retransmission
    next_state(:await_ack, state);
  end

  def await_ack({timeout, await_ack}, State=#state{sock=Sock, cid=ChId, msg=BinAck}) do
      IO.puts("#{inspect(self()} <- ack [application didn't respond]")
      Sock ! {datagram, ChId, BinAck}
      next_state(pack_sent, State)
  def await_ack({out, Ack}, State) do
      # set correct type for a piggybacked response
      Ack2 = case Ack of
          %CoAP.Message{type=con} -> %AckCoAP.Message{type=ack};
          Else -> Else
      end,
      go_pack_sent(Ack2, State).

  def go_pack_sent(Ack, State=#state{sock=Sock, cid=ChId}) do
    IO.inspect("~p <- ~p~n", [self(), Ack]),
    BinAck = coap_message_parser:encode(Ack),
    Sock ! {datagram, ChId, BinAck},
    next_state(pack_sent, State#state{msg=BinAck})
  end

  def pack_sent({in, _binary_message}, State=#state{sock=Sock, cid=ChId, msg=BinAck}) do
    # retransmit the ack
    Sock ! {datagram, ChId, BinAck},
    next_state(pack_sent, State)
  end

  # --- outgoing CON->ACK|RST

  def out_con({out, message}, State=#state{sock=Sock, cid=ChId}) do
    IO.inspect("~p, <= ~p~n", [self(), message]),
    binary_message = coap_message_parser:encode(message),
    Sock ! {datagram, ChId, binary_message},
    _ = :rand.seed(:exs1024),
    timeout = @ack_timeout+:rand.uniform(@ack_random_factor),
    next_state(await_pack, State#state{msg=message, retry_time=timeout, retry_count=0}, timeout)
  end

  # peer ack
  def await_pack({in, BinAck}, State) do
    case catch coap_message_parser:decode(BinAck) do
      %CoAP.Message{type=ack, method=nil} = Ack ->
        handle_ack(Ack, State);
      %CoAP.Message{type=reset} = Ack ->
        handle_error(Ack, reset, State);
      %CoAP.Message{} = Ack ->
        handle_response(Ack, State);
      {error, _Error} ->
        # shall we inform the receiver?
        ok
    end,
    next_state(ack_sent, State)
  end

  def await_pack({timeout, await_pack}, State=#state{sock=Sock, cid=ChId, msg=message, retry_time=timeout, retry_count=Count}) when Count < ?MAX_RETRANSMIT do
    binary_message = coap_message_parser:encode(message),
    Sock ! {datagram, ChId, binary_message},
    timeout2 = timeout*2,
    next_state(await_pack, State#state{retry_time=timeout2, retry_count=Count+1}, timeout2)
  end

  def await_pack({timeout, await_pack}, State=#state{tid={out, _MsgId}, msg=message}) do
    handle_error(message, timeout, State),
    next_state(ack_sent, State)
  end

  def ack_sent({in, _Ack}, State) do
    # ignore ack retransmission
    next_state(ack_sent, State)
  end

  # utility functions

  def timeout_after(time, channel, TrId, event) do
    :erlang.send_after(time, channel, {:timeout, TrId, event})
  end

  def handle_request(message, #state{cid=ChId, channel=channel, resp=ReSup, receiver=nil}) do
    IO.inspect([self(), message]),
    case coap_responder_sup:get_responder(ReSup, message) of
      {ok, Pid} ->
        Pid ! {coap_request, ChId, channel, nil, message},
        ok;
      {error, {not_found, _}} ->
        {ok, _} = coap_channel:send(channel,
          coap_message:response({error, not_found}, message)),
        ok
    end
  end

  def handle_request(message, #state{cid=ChId, channel=channel, receiver={Sender, Ref}}) do
    IO.inspect([self(), message]),
    Sender ! {coap_request, ChId, channel, Ref, message},
    ok
  end

  def handle_response(message, #state{cid=ChId, channel=channel, receiver={Sender, Ref}}) do
    IO.inspect([self(), message]),
    Sender ! {coap_response, ChId, channel, Ref, message},
    request_complete(channel, message)
  end

  def handle_error(message, Error, #state{cid=ChId, channel=channel, receiver={Sender, Ref}}) do
    IO.inspect([self(), message]),
    Sender ! {coap_error, ChId, channel, Ref, Error},
    request_complete(channel, message)
  end

  def handle_ack(_message, #state{cid=ChId, channel=channel, receiver={Sender, Ref}}) do
    IO.inspect([self(), message]),
    Sender ! {coap_ack, ChId, channel, Ref},
    ok
  end

  def request_complete(channel, %CoAP.Message{token: token, options: options}) do
    case :proplists.get_value(:observe, options, []) do
      [] ->
        channel ! {:request_complete, token}
        :ok
      _ ->
        :ok
    end
  end

  # start the timer
  def next_state(Phase, State=#state{channel=channel, tid=TrId, timer=nil}, timeout) do
    timer = timeout_after(timeout, channel, TrId, Phase),
    State#state{phase=Phase, timer=timer};
  end

  # restart the timer
  def next_state(Phase, State=#state{channel=channel, tid=TrId, timer=timer1}, timeout) do
    _ = :erlang.cancel_timer(timer1),
    timer2 = timeout_after(timeout, channel, TrId, Phase),
    State#state{phase=Phase, timer=timer2}.
  end

  def next_state(Phase, State=#state{timer=nil}) do
    State#state{phase=Phase};
  end

  def next_state(Phase, State=#state{phase=Phase1, timer=timer}) do
    if
      # when going to another phase, the timer is cancelled
      Phase /= Phase1 ->
        _ = :erlang.cancel_timer(timer),
        ok;
      # when staying in current phase, the timer continues
      true ->
        ok
    end
    State#state{phase=Phase, timer=nil}
  end

end
