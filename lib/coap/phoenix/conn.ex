defmodule CoAP.Phoenix.Conn do
  @moduledoc """
  (kind of) `Plug.Conn.Adapter` for CoAP
  """
  # @behaviour Plug.Conn.Adapter

  alias CoAP.Message

  @doc false
  @spec conn(map) :: Plug.Conn.t()
  def conn(req) do
    %{
      path: path,
      host: host,
      port: port,
      method: method,
      headers: headers,
      qs: qs,
      peer: {remote_ip, _},
      owner: owner
    } = req

    # Must be Plug.Conn for Phoenix to use it
    %Plug.Conn{
      adapter: {__MODULE__, req},
      host: host,
      method: to_method_string(method),
      owner: owner,
      path_info: split_path(path),
      port: port,
      remote_ip: remote_ip,
      query_string: qs,
      req_headers: to_headers_list(headers),
      request_path: path,
      scheme: "coap"
    }
  end

  @doc false
  def send_resp(req, status, _headers, body) do
    message = req.message
    connection = req.owner

    {code_class, code_detail} = Message.encode_status(status)

    result = %Message{
      type: :con,
      code_class: code_class,
      code_detail: code_detail,
      message_id: message.message_id,
      token: message.token,
      payload: body
    }

    send(connection, {:deliver, result})

    {:ok, nil, req}
  end

  @doc false
  def read_req_body(state, _opts) do
    {:ok, state[:message].payload, state}
  end

  @doc false
  def tag(conn, tag), do: send(conn.owner, {:tag, tag})

  ###
  ### Priv
  ###
  defp split_path(path) do
    path
    |> :binary.split("/", [:global])
    # Remove empty parts
    |> Enum.filter(fn part -> part != "" end)
  end

  defp to_headers_list(headers) when is_list(headers), do: headers
  defp to_headers_list(headers) when is_map(headers), do: :maps.to_list(headers)

  defp to_method_string(verb) when is_atom(verb) do
    verb |> Atom.to_string() |> String.upcase()
  end
end
