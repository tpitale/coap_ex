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

      assert_receive {:rr_rx, ^con, _}
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

    check all(
            non <- map(message(), &%{&1 | type: :non}),
            from <- inet_peer()
          ) do
      send(t, {:recv, non, from})

      assert_receive {:rr_rx, ^non, _}
      assert :closed = state_name(t)
    end
  end

  property ":closed[RX_RST] -> :closed[REMOVE_OBSERVER]" do
    t = start_transport()

    check all(
            rst <- map(message(), &%{&1 | type: :reset}),
            from <- inet_peer()
          ) do
      send(t, {:recv, rst, from})
      assert_receive {:rr_rx, ^rst, _}
      assert :closed = state_name(t)
    end
  end

  property ":closed[RX_ACK] -> :closed" do
    t = start_transport()

    check all(
            ack <- map(message(), &%{&1 | type: :ack}),
            from <- inet_peer()
          ) do
      send(t, {:recv, ack, from})
      refute_receive _
      assert :closed = state_name(t)
    end
  end

  property ":reliable_tx[RX_RST] -> :closed[RR_EVT(fail)]" do
    t = start_transport()

    check all(
            %Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con}),
            from <- inet_peer(),
            rst <- map(message(), &%{&1 | type: :reset, message_id: mid})
          ) do
      # Put FSM to reliable_tx state
      send(t, con)
      assert {:reliable_tx, ^mid} = state_name(t)

      send(t, {:recv, rst, from})
      assert_receive {:rr_fail, ^mid, :reset}
      assert :closed = state_name(t)
    end
  end

  property ":reliable_tx[M_CMD(cancel)] -> :closed" do
    t = start_transport()

    check all(%Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con})) do
      # Put FSM in reliable_tx state
      send(t, con)
      assert {:reliable_tx, ^mid} = state_name(t)

      send(t, {:cancel, mid})
      assert :closed = state_name(t)
    end
  end

  property ":reliable_tx[RX_ACK] -> :closed[RR_EVT(rx)]" do
    t = start_transport()

    check all(
            %Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con}),
            from <- inet_peer(),
            ack <- map(message(), &%{&1 | type: :ack, message_id: mid})
          ) do
      # Put FSM in reliable_tx state
      send(t, con)
      assert {:reliable_tx, ^mid} = state_name(t)

      send(t, {:recv, ack, from})
      assert_receive {:rr_rx, ^ack, _}
      assert :closed = state_name(t)
    end
  end

  property ":reliable_tx[RX_NON] -> :closed[RR_EVT(rx)]" do
    t = start_transport()

    check all(
            %Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con}),
            from <- inet_peer(),
            non <- map(message(), &%{&1 | type: :ack, message_id: mid})
          ) do
      # Put FSM in reliable_tx state
      send(t, con)
      assert {:reliable_tx, ^mid} = state_name(t)

      send(t, {:recv, non, from})
      assert_receive {:rr_rx, ^non, _}
      assert :closed = state_name(t)
    end
  end

  property ":reliable_tx[RX_CON] -> :ack_pending[RR_EVT(rx)]" do
    t = start_transport()

    check all(
            %Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con}),
            from <- inet_peer(),
            con2 <- map(message(), &%{&1 | type: :con, message_id: mid})
          ) do
      # Put FSM in reliable_tx state
      send(t, con)
      assert {:reliable_tx, ^mid} = state_name(t)

      send(t, {:recv, con2, from})
      assert_receive {:rr_rx, ^con2, _}
      assert {:ack_pending, ^mid} = state_name(t)

      send(t, :reset)
    end
  end

  property ":reliable_tx[TIMEOUT(RETX_TIMEOUT)] -> (max retry) -> :closed[RR_EVT(fail)]" do
    check all(
            con <- map(message(), &%{&1 | type: :con}),
            ack_timeout <- integer(50..150),
            max_retransmit <- integer(1..3),
            max_runs: 5
          ) do
      t = start_transport(ack_timeout: ack_timeout, max_retransmit: max_retransmit)
      retx_timeout = Transport.State.__max_transmit_wait__(ack_timeout, max_retransmit)

      send(t, con)
      :timer.sleep(retx_timeout)

      for _retry <- 1..(max_retransmit + 1) do
        assert_received {:send, ^con}
      end

      assert_receive {:rr_fail, _, :timeout}

      Transport.stop(t)
    end
  end

  property ":reliable_tx[TIMEOUT(RETX_TIMEOUT)] -> (retry) -> :closed[RR_EVT(rx)]" do
    timeout = 100
    t = start_transport(ack_timeout: timeout, max_retransmit: 2)

    check all(
            %Message{message_id: mid} = con <- map(message(), &%{&1 | type: :con}),
            from <- inet_peer(),
            ack <- map(message(), &%{&1 | type: :ack, message_id: mid}),
            max_runs: 5
          ) do
      send(t, con)
      assert_receive {:send, ^con}
      :timer.sleep(timeout)

      # First retry
      assert_receive {:send, ^con}

      # Send ACK
      send(t, {:recv, ack, from})

      assert_receive {:rr_rx, ^ack, _}
      assert :closed = state_name(t)

      send(t, :reset)
    end
  end

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
      timeout = Transport.State.__retransmit_timeout__(ack_timeout, ack_random_factor)

      assert timeout >= ack_timeout
      assert timeout <= round(ack_timeout * ack_random_factor)
    end
  end

  defp start_transport(options \\ []) do
    args = Keyword.merge([socket_adapter: Socket, socket_opts: self()], options)
    {:ok, t} = Transport.start({"example.org", 8080}, self(), args)

    t
  end

  defp state_name(t), do: GenStateMachine.call(t, :state_name)
end
