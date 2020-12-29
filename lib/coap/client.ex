defmodule CoAP.Client do
  @moduledoc """
  CoAP Client interface
  """
  alias CoAP.Client.Request
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
  @type method :: :get | :post | :put | :delete
  @type coap_options() :: Enumerable.t()
  @type payload() :: binary()
  @type url() :: binary()
  @type request() :: url() | {url(), coap_options()}
  @type response_error :: {:timeout, :await_response} | any
  @type response :: Message.t() | {:error, response_error}

  @doc """
  Perform GET request to a URL
  Returns a `CoAP.Message` response, or an error tuple

  CoAP.Client.get("coap://localhost:5683/api/")
  """
  @spec get(request(), options) :: response
  def get(req, options \\ []), do: request(:get, req, options)

  @doc """
  Perform POST request to a URL
  Returns a `CoAP.Message` response, or an error tuple
  Optionally takes a binary content payload

  CoAP.Client.post("coap://localhost:5683/api/", <<0x00, 0x01, …>>)
  """
  @spec post(request(), payload(), options) :: response
  def post(req, content \\ <<>>, options \\ [])

  def post(req, content, options) when is_binary(req),
    do: request(:post, {req, [], content}, options)

  def post({url, coap_options}, content, options),
    do: request(:post, {url, coap_options, content}, options)

  @doc """
  Perform PUT request to a URL
  Returns a `CoAP.Message` response, or an error tuple
  Optionally takes a binary content payload

  CoAP.Client.put("coap://localhost:5683/api/", "somepayload")
  """
  @spec put(request(), payload(), options) :: response
  def put(req, content \\ <<>>, options \\ [])

  def put(req, content, options) when is_binary(req),
    do: request(:put, {req, [], content}, options)

  def put({url, coap_options}, content, options),
    do: request(:put, {url, coap_options, content}, options)

  @doc """
  Perform a DELETE request to a URL
  Returns a `CoAP.Message` response, or an error tuple

  CoAP.Client.delete("coap://localhost:5683/api/")
  """
  @spec delete(request(), options) :: response
  def delete(req, options \\ [])

  def delete(req, options) when is_binary(req),
    do: request(:delete, {req, []}, options)

  def delete({url, coap_options}, options),
    do: request(:delete, {url, coap_options}, options)

  @doc """
  Perform a request

  Returns response message or error tuple
  """
  @spec request(method, Request.t(), options) :: response
  def request(method, request, options \\ []) do
    {:ok, {uri, message}} =
      Request.build(method, request, Keyword.get(options, :confirmable, true))

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
