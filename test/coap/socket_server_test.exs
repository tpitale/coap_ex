defmodule CoAP.SocketServerTest do
  use ExUnit.Case

  alias CoAP.SocketServer
  alias CoAP.Adapters.GenericServer

  @moduletag :capture_log

  defmodule FakeEndpoint do
  end

  test "decoding error" do
    peer_ip = "127.0.0.1"
    peer_port = 5830

    {:ok, server} = SocketServer.start_link([{GenericServer, FakeEndpoint}, peer_port])

    data =
      <<100, 69, 0, 1, 252, 1, 46, 56, 68, 80, 231, 168, 249, 100, 69, 0, 1, 252, 1, 46, 56, 68,
        80, 231, 168, 249>>

    send(server, {:udp, :socket, peer_ip, peer_port, data})

    response =
      receive do
        {:deliver, response, _peer} -> response
        {:error, reason} -> {:error, reason}
      after
        5_000 -> {:error, {:timeout, :await_response}}
      end

    assert response == {:error, {:timeout, :await_response}}
  end

  test "decoding CaseClauseError" do
    peer_ip = "127.0.0.1"
    peer_port = 5830

    {:ok, server} = SocketServer.start_link([{GenericServer, FakeEndpoint}, peer_port])

    data =
      <<100, 69, 0, 1, 83, 61, 239, 152, 68, 244, 81, 253, 46, 100, 69, 0, 1, 83, 61, 239, 152, 68, 244, 81, 253, 46>>

    send(server, {:udp, :socket, peer_ip, peer_port, data})

    response =
      receive do
        {:deliver, response, _peer} -> response
        {:error, reason} -> {:error, reason}
      after
        5_000 -> {:error, {:timeout, :await_response}}
      end

    assert response == {:error, {:timeout, :await_response}}
  end
end
