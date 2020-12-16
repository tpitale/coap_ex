defmodule CoAP.TransportTest do
  use CoAP.Test.Support.DataCase

  alias CoAP.Test.Support.Socket
  alias CoAP.Transport

  setup do
    {:ok, pid} = Transport.start_link(socket_init: &Socket.init/1, transport_opts: self())

    [t: pid]
  end

  property ":closed[M_CMD(reliable_send)] -> TX(con)", %{t: t} do
    check all(message <- map(message(), &%{&1 | type: :con})) do
      send(t, {:reliable_send, message})
      assert_receive {:send, ^message, nil}
      send(t, :cancel)
    end
  end
end
