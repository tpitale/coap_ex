defmodule CoAP.Client do
  @moduledoc """
  CoAP Client interface
  """
  alias CoAP.Message
  alias CoAP.Transport

  # Default timeout: 5 sec
  @default_timeout 5_000
  @message_opts [:ack_timeout, :max_retransmit, :socket_adapter, :socket_opts]

  @type option() ::
          {:ack_timeout, integer()}
          | {:max_retransmit, integer()}
          | {:socket_adapter, module()}
          | {:socket_opts, any()}
          | {:timeout, integer()}
          | {:confirmable, boolean()}

  @typedoc """
  Options related to Message layer behaviour:
  * `ack_timeout`: initial timeout for receiving ack
  * `max_retransmit`: max retransmission attempts
  * `socket_adapter`: module implementing `CoAP.Transport` behaviour. Default
    is to infer from peer URI.
  * `socket_opts`: options passed to socket adapter

  Options related to Request/Response layer
  * `timeout`: timeout for receiving response
  * `confirmable`: if true, request is confirmable
  """
  @type options :: [option()]
  @type request_url :: binary
  @type request_method :: :get | :post | :put | :delete
  @type response_error :: {:timeout, :await_response} | any
  @type response :: Message.t() | {:error, response_error}

  @doc """
  Perform GET request to a URL
  Returns a `CoAP.Message` response, or an error tuple

  CoAP.Client.get("coap://localhost:5683/api/")
  """
  @spec get(request_url, options) :: response
  def get(url, options \\ []), do: request(:get, url, <<>>, options)

  @doc """
  Perform POST request to a URL
  Returns a `CoAP.Message` response, or an error tuple
  Optionally takes a binary content payload

  CoAP.Client.post("coap://localhost:5683/api/", <<0x00, 0x01, …>>)
  """
  @spec post(request_url, binary, options) :: response
  def post(url, content \\ <<>>, options), do: request(:post, url, content, options)

  @doc """
  Perform PUT request to a URL
  Returns a `CoAP.Message` response, or an error tuple
  Optionally takes a binary content payload

  CoAP.Client.put("coap://localhost:5683/api/", "somepayload")
  """
  @spec put(request_url, binary, options) :: response
  def put(url, content \\ <<>>, options \\ []), do: request(:put, url, content, options)

  @doc """
  Perform a DELETE request to a URL
  Returns a `CoAP.Message` response, or an error tuple

  CoAP.Client.delete("coap://localhost:5683/api/")
  """
  @spec delete(request_url, options) :: response
  def delete(url, options \\ []), do: request(:delete, url, <<>>, options)

  @doc """
  Perform a request

  Accepts 3-5 arguments:
  * method: 1 of :get, :post, :put :delete
  * url: binary, parseable by `URI.parse()`
  * content (optional): a binary payload
  * options (optional): see `options()` typespec

  Returns response message or error tuple
  """
  @spec request(request_method, request_url, binary, options) :: response
  def request(method, url, content \\ <<>>, options \\ []) do
    uri = URI.parse(url)
    {code_class, code_detail} = Message.encode_method(method)

    message = %Message{
      request: true,
      type: if(Keyword.get(options, :confirmable, true), do: :con, else: :non),
      method: method,
      token: :crypto.strong_rand_bytes(4),
      code_class: code_class,
      code_detail: code_detail,
      payload: content,
      options: %{uri_path: String.split(uri.path, "/")}
    }

    fn -> do_request(uri, message, options) end
    |> Task.async()
    |> Task.await(:infinity)
  end

  ###
  ### Private
  ###
  defp do_request(uri, message, options) do
    {message_opts, rr_opts} = Keyword.split(options, @message_opts)
    {:ok, transport} = Transport.start_link(self(), [{:peer, uri} | message_opts])

    try do
      send(transport, message)
      timeout = Keyword.get(rr_opts, :timeout, @default_timeout)
      %Message{token: token, message_id: mid} = message
      start_time = System.monotonic_time(:millisecond)
      waiting(transport, mid, token, start_time, timeout)
    after
      _ = Transport.stop(transport)
    end
  end

  defp waiting(transport, mid, token, start_time, timeout) do
    receive do
      {:rr_fail, ^mid, reason} ->
        {:error, reason}

      {:rr_rx, %Message{type: :ack, message_id: ^mid, token: ^token, payload: <<>>}, _peer} ->
        # Separate response
        timeout = max(0, timeout - (System.monotonic_time(:millisecond) - start_time))
        waiting_separate(transport, token, timeout)

      {:rr_rx, %Message{type: :ack, message_id: ^mid, token: ^token} = m, _peer} ->
        # Piggybacked response
        m

      {:rr_rx, %Message{type: :non, token: ^token} = m, _peer} ->
        # Non confirmable response
        m
    after
      timeout ->
        {:error, {:timeout, :await_response}}
    end
  end

  defp waiting_separate(transport, token, timeout) do
    receive do
      {:rr_rx, %Message{type: :non, token: ^token} = m, _peer} ->
        m

      {:rr_rx, %Message{type: :con, token: ^token} = m, _peer} ->
        send(transport, Message.response_for(m))
        m
    after
      timeout ->
        {:error, {:timeout, :await_response}}
    end
  end
end
