defmodule CoAP.Adapters.Phoenix do
  @connection CoAP.Phoenix.Conn

  alias CoAP.Phoenix.Request

  import Logger, only: [warn: 1]

  @moduledoc """
  1. Take a message
  2. Convert to Plug.Conn
  3. Dispatch to phoenix Endpoint
  4. Accept result
  5. Return result in message form
  """

  def request(message, {endpoint, peer}, owner) do
    config = endpoint.config(:coap)

    message
    |> Request.build(peer, owner, config)
    |> process({endpoint, config})
  end

  # unlikely to use, as this is not a client
  # def response(message, {endpoint, peer})
  # def ack({endpoint, _peer})
  def error({endpoint, context}) do
    warn("CoAP Endpoint #{inspect(endpoint)} received an error #{inspect(context)}")
  end

  defp process(req, {endpoint, opts}) do
    case endpoint.__handler__(@connection.conn(req), opts) do
      {:plug, conn, handler, opts} ->
        %{adapter: {@connection, _req}} =
          conn
          |> handler.call(opts)
          |> maybe_send(handler)
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

  defp maybe_send(%Plug.Conn{state: :unset}, _plug), do: raise(Plug.Conn.NotSentError)
  defp maybe_send(%Plug.Conn{state: :set} = conn, _plug), do: Plug.Conn.send_resp(conn)
  defp maybe_send(%Plug.Conn{} = conn, _plug), do: conn

  defp maybe_send(other, plug) do
    raise "Cowboy2 adapter expected #{inspect(plug)} to return Plug.Conn but got: " <>
            inspect(other)
  end
end
