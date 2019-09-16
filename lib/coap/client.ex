defmodule CoAP.Client do
  @moduledoc """
    CoAP Client interface
  """
  alias CoAP.Message

  import Logger, only: [debug: 1]

  @type request_url :: binary
  @type request_type :: :con | :non | :ack | :reset
  @type request_method :: :get | :post | :put | :delete
  @type response :: CoAP.Message.t() | {:error, any}

  defmodule Options do
    # spec default for max_retransmits
    @max_retries 4
    @wait_timeout 10_000

    @type t :: %__MODULE__{
            retries: integer,
            retry_timeout: integer,
            timeout: integer,
            ack_timeout: integer,
            tag: any
          }

    defstruct retries: @max_retries,
              retry_timeout: nil,
              timeout: @wait_timeout,
              ack_timeout: nil,
              tag: nil
  end

  # TODO: options: headers/params?

  @doc """
    Perform a confirmable, GET request to a URL
    Returns a `CoAP.Message` response, or an error tuple
    Optionally takes a binary content payload

    CoAP.Client.get("coap://localhost:5683/api/")
  """
  @spec get(request_url, binary) :: response
  def get(url, content \\ <<>>), do: con(:get, url, content)

  @doc """
    Perform a confirmable, POST request to a URL
    Returns a `CoAP.Message` response, or an error tuple
    Optionally takes a binary content payload

    CoAP.Client.post("coap://localhost:5683/api/", <<0x00, 0x01, …>>)
  """
  @spec post(request_url, binary) :: response
  def post(url, content \\ <<>>), do: con(:post, url, content)

  @doc """
    Perform a confirmable, PUT request to a URL
    Returns a `CoAP.Message` response, or an error tuple
    Optionally takes a binary content payload

    CoAP.Client.put("coap://localhost:5683/api/", "somepayload")
  """
  @spec put(request_url, binary) :: response
  def put(url, content \\ <<>>), do: con(:put, url, content)

  @doc """
    Perform a confirmable, DELETE request to a URL
    Returns a `CoAP.Message` response, or an error tuple

    CoAP.Client.delete("coap://localhost:5683/api/")
  """
  @spec delete(request_url) :: response
  def delete(url), do: con(:delete, url)

  @doc """
    Perform a confirmable request of any method (get/post/put/delete)
    Returns a `CoAP.Message` response, or an error tuple

    CoAP.Client.con(:get, "coap://localhost:5683/api/", "somepayload")
  """
  @spec con(request_method, request_url, binary) :: response
  def con(method, url, content \\ <<>>), do: request(:con, method, url, content)
  # defp non(method, url), do: request(:non, method, url)
  # defp ack(method, url), do: request(:ack, method, url)
  # defp reset(method, url), do: request(:reset, method, url)

  @doc """
    Perform a request

    Accepts 3-5 arguments:
    * type: 1 of :con, :non, :ack, :reset
    * method: 1 of :get, :post, :put :delete
    * url: binary, parseable by `:uri_string.parse`
    * optional content: a binary payload
    * optional options: a map of options - retries, retry_timeout, and timeout

    Returns the binary of the response
  """
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
