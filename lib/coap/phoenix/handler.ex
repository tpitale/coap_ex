defmodule CoAP.Phoenix.Handler do
  # TODO: our own conn module
  @connection CoAP.Phoenix.Conn

  # TODO: make this a gen_server that has a process for each message?
  # TODO: or make a simple process, with start_link, to be supervised
  # TODO: add each one to a HandlerSupervisor
  # TODO: pool of handlers, or infinite?

  def init(req, {endpoint, opts}) do
    %{path_info: path_info} = conn = @connection.conn(req)

    IO.inspect(conn)

    try do
      case endpoint.__dispatch__(path_info, opts) do
        {:plug, handler, opts} ->
          %{adapter: {@connection, req}} =
            conn
            |> handler.call(opts)
            |> maybe_send(handler)

          {:ok, req, {handler, opts}}
      end
    catch
      :error, value ->
        stack = System.stacktrace()
        exception = Exception.normalize(:error, value, stack)
        exit({{exception, stack}, {endpoint, :call, [conn, opts]}})

      :throw, value ->
        stack = System.stacktrace()
        exit({{{:nocatch, value}, stack}, {endpoint, :call, [conn, opts]}})

      :exit, value ->
        exit({value, {endpoint, :call, [conn, opts]}})
    after
      receive do
        @already_sent -> :ok
      after
        0 -> :ok
      end
    end
  end

  # TODO: our Connection response rather than Plug.Conn.send_resp(conn)
  defp maybe_send(%Plug.Conn{state: :set} = conn, _plug), do: :nothing
  defp maybe_send(%Plug.Conn{state: :unset}, _plug), do: raise(Plug.Conn.NotSentError)
  defp maybe_send(%Plug.Conn{} = conn, _plug), do: conn

  defp maybe_send(other, plug) do
    raise "Cowboy2 adapter expected #{inspect(plug)} to return Plug.Conn but got: " <>
      inspect(other)
  end
end
