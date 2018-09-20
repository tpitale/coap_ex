defmodule CoAP.Phoenix.Adapter do
  @connection CoAP.Phoenix.Conn

  alias CoAP.Phoenix.Request

  # import Logger, only: [info: 1]

  @moduledoc """
  1. Take a message
  2. Convert to Plug.Conn
  3. Dispatch to phoenix Endpoint
  4. Accept result
  5. Return result in message form
  """

  def request(message, {endpoint, peer}) do
    config = endpoint.config(:coap)

    message
    |> Request.build(peer, config)
    |> process({endpoint, config})
    |> maybe_send()
    # TODO: what are opts supposed to be?
    # Answer: config from coap key for endpoint
  end

  # unlikely to use, as this is not a client
  # def response(message, {endpoint, peer})
  # def ack({endpoint, _peer})
  # def error({endpoint, _peer})

  defp process(req, {endpoint, opts}) do
    # TODO: conn_from_message(message)
    %{path_info: path_info} = conn = @connection.conn(req)

    case endpoint.__dispatch__(path_info, opts) do
      {:plug, handler, opts} ->
        %{adapter: {@connection, _req}} =
          conn
          |> handler.call(opts)
      # TODO: not found 404 if no plug?
    end

    # try do
    #   case endpoint.__dispatch__(path_info, opts) do
    #     {:plug, handler, opts} ->
    #       %{adapter: {@connection, req}} =
    #         conn
    #         |> handler.call(opts)
    #         |> maybe_send(handler)
    #
    #       {:ok, req, {handler, opts}}
    #   end
    # catch
    #   :error, value ->
    #     stack = System.stacktrace()
    #     exception = Exception.normalize(:error, value, stack)
    #     exit({{exception, stack}, {endpoint, :call, [conn, opts]}})
    #
    #   :throw, value ->
    #     stack = System.stacktrace()
    #     exit({{{:nocatch, value}, stack}, {endpoint, :call, [conn, opts]}})
    #
    #   :exit, value ->
    #     exit({value, {endpoint, :call, [conn, opts]}})
    # after
    #   receive do
    #     @already_sent -> :ok
    #   after
    #     0 -> :ok
    #   end
    # end
  end

  # TODO: our Connection response rather than Plug.Conn.send_resp(conn)
  defp maybe_send(%Plug.Conn{state: :unset}), do: raise(Plug.Conn.NotSentError)
  defp maybe_send(%Plug.Conn{state: :set} = conn), do: conn
  # defp maybe_send(%Plug.Conn{} = conn), do: conn

  defp maybe_send(other) do
    raise "CoAP adapter expected to return Plug.Conn but got: " <>
      inspect(other)
  end
end
