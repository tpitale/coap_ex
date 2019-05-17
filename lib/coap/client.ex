defmodule CoAP.Client do
  @moduledoc """
    CoAP Client interface
  """
  alias CoAP.Message

  import Logger, only: [debug: 1]

  @type request_url :: binary
  @type request_type :: :con | :non | :ack | :reset
  @type request_method :: :get | :post | :put | :delete
  @type response :: binary | {:error, any}

  defmodule Options do
    # spec default for max_retransmits
    @max_retries 4
    @wait_timeout 10_000

    @type t :: %__MODULE__{retries: integer, retry_timeout: integer, timeout: integer}

    defstruct retries: @max_retries, retry_timeout: nil, timeout: @wait_timeout
  end

  # TODO: options: headers/params?

  @spec get(request_url) :: response
  def get(url), do: con(:get, url)
  @spec get(request_url, binary) :: response
  def get(url, content), do: con(:get, url, content)
  @spec post(request_url) :: response
  def post(url), do: con(:post, url)
  @spec post(request_url, binary) :: response
  def post(url, content), do: con(:post, url, content)
  @spec put(request_url) :: response
  def put(url), do: con(:put, url)
  @spec put(request_url, binary) :: response
  def put(url, content), do: con(:put, url, content)
  @spec delete(request_url) :: response
  def delete(url), do: con(:delete, url)

  @spec con(request_method, request_url) :: response
  def con(method, url), do: request(:con, method, url)
  @spec con(request_method, request_url, binary) :: response
  def con(method, url, content), do: request(:con, method, url, content)
  # defp non(method, url), do: request(:non, method, url)
  # defp ack(method, url), do: request(:ack, method, url)
  # defp reset(method, url), do: request(:reset, method, url)

  @spec request(request_type, request_method, request_url, binary, map) ::
          response
  def request(type, method, url, content \\ <<>>, options \\ %{}) do
    uri = :uri_string.parse(url)

    host = uri[:host]
    port = uri[:port]
    token = :crypto.strong_rand_bytes(4)

    options = struct(Options, options)

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

    debug("Client Request: #{inspect(message)}")

    {:ok, connection} = CoAP.Connection.start_link([self(), {host, port, token}, options])

    send(connection, {:deliver, message})

    await_response(message, options.timeout)
  end

  defp await_response(_message, timeout) do
    receive do
      {:deliver, response, _peer} -> response
      {:error, reason} -> {:error, reason}
    after
      timeout -> {:error, {:timeout, :await_response}}
    end
  end
end
