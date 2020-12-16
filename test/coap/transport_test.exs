defmodule CoAP.TransportTest do
  use CoAP.Test.Support.DataCase

  alias CoAP.Test.Support.Socket
  alias CoAP.Transport

  property ":closed[M_CMD(reliable_send)] -> TX(con)" do
    check all(message <- map(message(), &%{&1 | type: :con})) do
      t = start_transport()

      send(t, {:reliable_send, message})
      assert_receive {:send, ^message, nil}

      stop_transport(t)
    end
  end

  property ":reliable_tx[timeout(retx_timeout)] -> RR_EVT(fail)" do
    check all(
            message <- map(message(), &%{&1 | type: :con}),
            ack_timeout <- integer(50..150),
            max_retransmit <- integer(1..3),
            max_runs: 5
          ) do
      t = start_transport(ack_timeout: ack_timeout, max_retransmit: max_retransmit)
      retx_timeout = Transport.__max_transmit_wait__(ack_timeout, max_retransmit)

      send(t, {:reliable_send, message})
      :timer.sleep(retx_timeout)

      for _retry <- 1..(max_retransmit + 1) do
        assert_received {:send, ^message, _}
      end

      assert_receive {^t, :fail}

      stop_transport(t)
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

  defp stop_transport(t), do: send(t, :stop)
end
