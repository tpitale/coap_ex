defmodule CoAP.Phoenix.Conn do
  # @behaviour Plug.Conn.Adapter

  def conn(req) do
    %{
      path: path,
      host: host,
      port: port,
      method: method,
      headers: headers,
      qs: qs,
      peer: {remote_ip, _}
    } = req

    # Must be Plug.Conn for Phoenix to use it
    %Plug.Conn{
      adapter: {__MODULE__, req},
      host: host,
      method: method |> to_method_string(),
      owner: self(), # TODO: is this right?
      path_info: split_path(path),
      port: port,
      remote_ip: remote_ip,
      query_string: qs,
      req_headers: to_headers_list(headers),
      request_path: path,
      scheme: "coap" # TODO: coaps
    }
  end

  def send_resp(req, status, headers, body) do
    IO.puts("#{inspect(req)} returns #{inspect(status)}, #{inspect(headers)}, #{inspect(body)}")

    # TODO: change headers into message options
    # headers = to_headers_map(headers)

    # TODO: where does status go?
    # status = Integer.to_string(status) <> " " <> Plug.Conn.Status.reason_phrase(status)

    # TODO: udp send encoded message, body as payload
    # req = :cowboy_req.reply(status, headers, body, req)

    {:ok, nil, req}
  end

  defp split_path(path) do
    segments = :binary.split(path, "/", [:global])
    # TODO: use enum reject?
    for segment <- segments, segment != "", do: segment
  end

  defp to_headers_list(headers) when is_list(headers) do
    headers
  end

  defp to_headers_list(headers) when is_map(headers) do
    :maps.to_list(headers)
  end

  defp to_method_string(verb) when is_atom(verb) do
    verb |> Atom.to_string |> String.upcase
  end
end
