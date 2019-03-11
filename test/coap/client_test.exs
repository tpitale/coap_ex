defmodule CoAP.ClientTest do
  use ExUnit.Case
  doctest CoAP.Client

  alias CoAP.Message

  @port 5827

  defmodule FakeEndpoint do
    def request(message) do
      # path should have api in it
      # params should be empty
      # IO.inspect(message)

      %Message{
        type: :con,
        code_class: 2,
        code_detail: 1,
        message_id: message.message_id,
        token: message.token,
        payload: "Created"
      }
    end
  end

  test "get" do
    # pass a module that has a response
    # endpoint = Task.new(fn)
    # start a socket server
    {:ok, _server} =
      CoAP.SocketServer.start_link([@port, {CoAP.Adapters.GenericServer, FakeEndpoint}])

    # make a request with the client
    response = CoAP.Client.get("coap://127.0.0.1:#{@port}/api")

    assert response.message_id > 0
    assert response.code_class == 2
    assert response.code_detail == 1
    assert response.payload == "Created"
  end
end
