defmodule CoAP.TransportTest do
  use CoAP.Test.Support.DataCase

  alias CoAP.Message
  alias CoAP.Test.Support.Socket
  alias CoAP.Transport

  property ":closed[M_CMD(reliable_send)] -> :reliable_tx[TX(con)]" do
    t = start_transport()

    check all(%Message{message_id: id} = con <- map(message(), &%{&1 | type: :con})) do
      send(t, con)
      assert_receive {:send, ^con}
      assert {:reliable_tx, ^id} = state_name(t)

      send(t, :reset)
    end
  end

  property ":closed[RX_CON] -> :ack_pending[RR_EVT(rx)]" do
    t = start_transport()

    check all(
            %Message{message_id: id} = con <- map(message(), &%{&1 | type: :con}),
            from <- inet_peer()
          ) do
      send(t, {:recv, con, from})

      assert_receive {^t, {:rr_rx, ^con}}
      assert {:ack_pending, ^id} = state_name(t)

      send(t, :reset)
    end
  end

  property ":closed[M_CMD(unreliable_send)] -> :closed[TX(non)]" do
    t = start_transport()

    check all(non <- map(message(), &%{&1 | type: :non})) do
      send(t, non)

      assert_receive {:send, ^non}
      assert :closed = state_name(t)

      send(t, :reset)
    end
  end

  property ":closed[RX_NON] -> :closed[RR_EVT(rx)]" do
    t = start_transport()

    check all(non <- map(message(), &%{&1 | type: :non})) do
      send(t, {:recv, non})

      assert_receive {^t, {:rr_rx, ^non}}
      assert :closed = state_name(t)
    end
  end

  # property ":closed[RX_RST] -> :closed[REMOVE_OBSERVER]"

  property ":closed[RX_ACK] -> :closed" do
    t = start_transport()

    check all(ack <- map(message(), &%{&1 | type: :ack})) do
      send(t, {:recv, ack})
      refute_receive _
      assert :closed = state_name(t)
    end
  end

  property ":reliable_tx[timeout(retx_timeout)] -> :closed[RR_EVT(fail)]" do
    check all(
            con <- map(message(), &%{&1 | type: :con}),
            ack_timeout <- integer(50..150),
            max_retransmit <- integer(1..3),
            max_runs: 5
          ) do
      t = start_transport(ack_timeout: ack_timeout, max_retransmit: max_retransmit)
      retx_timeout = Transport.__max_transmit_wait__(ack_timeout, max_retransmit)

      send(t, con)
      :timer.sleep(retx_timeout)

      for _retry <- 1..(max_retransmit + 1) do
        assert_received {:send, ^con}
      end

      assert_receive {^t, :rr_fail}

      stop_transport(t)
    end
  end

  property ":reliable_tx[RX_RST] -> :closed[RR_EVT(fail)]" do
    t = start_transport()

    check all(
            %Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con}),
            rst <- map(message(), &%{&1 | type: :reset})
          ) do
      # Put FSM to reliable_tx state
      send(t, con)
      assert {:reliable_tx, ^mid} = state_name(t)

      send(t, {:recv, rst})
      assert_receive {^t, :rr_fail}
      assert :closed = state_name(t)
    end
  end

  # property ":reliable_tx[M_CMD(cancel)] -> :closed"

  # property ":reliable_tx[RX_ACK] -> :closed[RR_EVT(rx)]"

  # property ":reliable_tx[RX_NON] -> :closed[RR_EVT(rx)]"

  # property ":reliable_tx[RX_CON] -> :ack_pending[RR_EVT(rx)]"

  # property ":reliable_tx[TIMEOUT(RETX_TIMEOUT)] -> :reliable_tx[TX(con)]"

  property ":ack_pending[M_CMD(accept)] -> :closed[TX(ack)]" do
    t = start_transport()

    check all(
            %Message{message_id: id} = con <- map(message(), &%{&1 | type: :con}),
            ack <- map(message(), &%{&1 | message_id: id, type: :ack}),
            from <- inet_peer()
          ) do
      # Put FSM to ack_pending state
      send(t, {:recv, con, from})
      assert {:ack_pending, ^id} = state_name(t)

      # RR layer sends ACK
      send(t, ack)
      assert_receive {:send, ^ack}
      assert :closed = state_name(t)
    end
  end

  property "retransmit_timeout" do
    check all(
            ack_timeout <- positive_integer(),
            ack_random_factor <- float(min: 1.0, max: 2.0)
          ) do
      timeout = Transport.__retransmit_timeout__(ack_timeout, ack_random_factor)

      assert timeout >= ack_timeout
      assert timeout <= round(ack_timeout * ack_random_factor)
    end
  end

  defp start_transport(options \\ []) do
    args = Keyword.merge([socket_init: &Socket.init/1, transport_opts: self()], options)
    {:ok, t} = Transport.start(self(), args)

    t
  end

  defp stop_transport(t),
    do: GenStateMachine.stop(t, :normal)

  defp state_name(t), do: GenStateMachine.call(t, :state_name)
end
