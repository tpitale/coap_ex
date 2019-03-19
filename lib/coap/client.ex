defmodule CoAP.Client do
  alias CoAP.Message

  @wait_timeout 10_000

  # TODO: options: headers/params?

  def get(url), do: con(:get, url)
  def get(url, content), do: con(:get, url, content)
  def post(url), do: con(:post, url)
  def post(url, content), do: con(:post, url, content)
  def put(url), do: con(:put, url)
  def put(url, content), do: con(:put, url, content)
  def delete(url), do: con(:delete, url)

  def con(method, url), do: request(:con, method, url)
  def con(method, url, content), do: request(:con, method, url, content)
  # defp non(method, url), do: request(:non, method, url)
  # defp ack(method, url), do: request(:ack, method, url)
  # defp reset(method, url), do: request(:reset, method, url)

  def request(type, method, url), do: request(type, method, url, <<>>)

  def request(type, method, url, content) do
    uri = :uri_string.parse(url)

    # TODO: what if this is a hostname?
    host = uri[:host]
    port = uri[:port]
    token = :crypto.strong_rand_bytes(4)

    {code_class, code_detail} = Message.encode_method(method)

    message = %Message{
      request: true,
      type: type,
      method: method,
      token: token,
      code_class: code_class,
      code_detail: code_detail,
      payload: content,
      options: %{uri_path: String.split(uri[:path], "/")}
    }

    # TODO: peer = {ip, port, token} = Message.peer_from(message)

    # TODO: start a connection
    # server = CoAP.SocketServer.start_link([0, {CoAP.Adapters.Client, self()}])
    {:ok, connection} = CoAP.Connection.start_link([self(), {host, port, token}])

    # TODO: deliver request
    send(connection, {:deliver, message})

    # TODO: await response
    await_response(message)
  end

  defp await_response(_message) do
    receive do
      {:deliver, response, _peer} -> response
    after
      @wait_timeout -> %Message{}
    end
  end
end
