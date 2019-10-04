defmodule CoAP.ClientTest do
  use ExUnit.Case, async: false
  doctest CoAP.Client

  alias CoAP.Message

  @port 5827

  defmodule FakeEndpoint do
    def request(message) do
      # path should have api in it
      # params should be empty

      payload =
        case message.payload do
          data when byte_size(data) > 0 -> data
          _ -> "Created"
        end

      %Message{
        type: :con,
        code_class: 2,
        code_detail: 1,
        message_id: message.message_id,
        token: message.token,
        payload: payload
      }
    end
  end

  # defmodule SlowBadEndpoint do
  #   def request(message) do
  #     # path should have api in it
  #     # params should be empty
  #
  #     payload =
  #       case message.payload do
  #         data when byte_size(data) > 0 -> data
  #         _ -> "Created"
  #       end
  #
  #     # sleep for longer than timeout
  #     Process.sleep(4000)
  #
  #     %Message{
  #       type: :con,
  #       code_class: 2,
  #       code_detail: 1,
  #       message_id: message.message_id,
  #       token: message.token,
  #       payload: payload
  #     }
  #   end
  # end

  defmodule BigResponseFakeEndpoint do
    def request(message) do
      # path should have api in it
      # params should be empty

      payload = StreamData.binary(length: 1024) |> Enum.take(1) |> hd()

      %Message{
        type: :con,
        code_class: 2,
        code_detail: 5,
        message_id: message.message_id,
        token: message.token,
        payload: payload
      }
    end
  end

  defmodule SlowEchoConnection do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    def init(args) do
      Process.flag(:trap_exit, true)
      {:ok, args}
    end

    def handle_info({:deliver, message}, state) do
      [client_pid, cid, _options] = state

      Process.sleep(1000)

      send(client_pid, {:deliver, message, cid})

      {:noreply, state}
    end
  end

  test "get" do
    # pass a module that has a response
    # endpoint = Task.new(fn)
    # start a socket server
    CoAP.SocketServer.start([{CoAP.Adapters.GenericServer, FakeEndpoint}, @port + 1])

    # make a request with the client
    response = CoAP.Client.get("coap://localhost:#{@port + 1}/api")

    assert response.message_id > 0
    assert response.code_class == 2
    assert response.code_detail == 1
    assert response.payload == "Created"
  end

  test "get with a big response payload" do
    CoAP.SocketServer.start([{CoAP.Adapters.GenericServer, BigResponseFakeEndpoint}, @port + 2])

    # make a request with the client
    response = CoAP.Client.get("coap://127.0.0.1:#{@port + 2}/api")

    assert response.message_id > 0
    assert response.code_class == 2
    assert response.code_detail == 5
    assert byte_size(response.payload) == 1024
  end

  test "post with big request payload" do
    CoAP.SocketServer.start([{CoAP.Adapters.GenericServer, FakeEndpoint}, @port + 3])

    payload = StreamData.binary(length: 1024) |> Enum.take(1) |> hd()

    response = CoAP.Client.post("coap://127.0.0.1:#{@port + 3}/api", payload)

    assert byte_size(response.payload) == 1024
  end

  test "put with big request payload" do
    CoAP.SocketServer.start([{CoAP.Adapters.GenericServer, FakeEndpoint}, @port + 4])

    payload = StreamData.binary(length: 2048) |> Enum.take(1) |> hd()

    response = CoAP.Client.put("coap://127.0.0.1:#{@port + 4}/api", payload)

    assert byte_size(response.payload) == 2048
  end

  test "get with slow response" do
    response =
      CoAP.Client.request(:con, :get, "coap://127.0.0.1:#{@port + 5}/api", <<>>, %{
        connection_module: SlowEchoConnection,
        timeout: 500
      })

    assert response == {:error, {:timeout, :await_response}}
  end
end
