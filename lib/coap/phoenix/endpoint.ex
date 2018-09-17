defmodule CoAP.Phoenix.Endpoint do
  # TODO: our own conn module
  @connection CoAP.Phoenix.Conn

  alias CoAP.Phoenix.Request

  # TODO: make this a gen_server that has a process for each message?
  # TODO: or make a simple process, with start_link, to be supervised
  # TODO: add each one to a HandlerSupervisor
  # TODO: pool of handlers, or infinite?

  @moduledoc """
  1. Take a message
  2. Convert to Plug.Conn
  3. Dispatch to phoenix Endpoint
  4. Accept result
  5. Return result in message form
  """

  def request(message, {endpoint, peer}) do
    message
    |> Request.build(message, peer)
    |> process({endpoint})
  end

  # unlikely to use, as this is not a client
  # def response(message, {endpoint, peer})
  # def ack({endpoint, _peer})
  # def error({endpoint, _peer})

  # TODO: parse message to phoenix request/conn


  defp process(req, {endpoint, opts}) do
    # TODO: conn_from_message(message)
    %{path_info: path_info} = conn = @connection.conn(req)

    IO.inspect(conn)

    case endpoint.__dispatch__(path_info, opts) do
      {:plug, handler, opts} ->
        %{adapter: {@connection, req}} =
          conn
          |> handler.call(opts)
          |> maybe_send(handler)

        {:ok, req, {handler, opts}}
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
  defp maybe_send(%Plug.Conn{state: :unset}, _plug), do: raise(Plug.Conn.NotSentError)
  defp maybe_send(%Plug.Conn{state: :set} = conn, _plug), do: conn
  # defp maybe_send(%Plug.Conn{} = conn, _plug), do: conn

  defp maybe_send(other, plug) do
    raise "CoAP adapter expected #{inspect(plug)} to return Plug.Conn but got: " <>
      inspect(other)
  end
end
