defmodule CoAP.Phoenix.Request do
  @moduledoc """
  Wraps CoAP.Message to transform it for use by CoAP.Phoenix.Conn
  """

  alias CoAP.Message

  # +------+--------+-----------+
  # | Code | Name   | Reference |
  # +------+--------+-----------+
  # | 0.01 | GET    | [RFC7252] |
  # | 0.02 | POST   | [RFC7252] |
  # | 0.03 | PUT    | [RFC7252] |
  # | 0.04 | DELETE | [RFC7252] |
  # +------+--------+-----------+
  # code_class => 0
  # code_detail => @methods
  @methods %{
    {0, 1} => :get,
    {0, 2} => :post,
    {0, 3} => :put,
    {0, 4} => :delete
  }

  @doc """
  Accept a Message, build a request map; include socket

  Examples:

      iex> message = %CoAP.Message{
      iex>   version: 1,
      iex>   type: 0,
      iex>   code_class: 0,
      iex>   code_detail: 3,
      iex>   message_id: 12796,
      iex>   token: <<123, 92, 211, 222>>,
      iex>   options: %{"Uri-Path" => "resource", "Uri-Query" => "who=world", "Uri-Host" => "localhost"},
      iex>   payload: "payload"
      iex> }
      iex> CoAP.Phoenix.Request.build(message, "socket", {127,0,0,1}, 5683)
      %{
        headers: %{
          "Uri-Path" => "resource",
          "Uri-Query" => "who=world",
          "Uri-Host" => "localhost"
        },
        host: "localhost",
        method: :put,
        path: "resource",
        peer: {{127,0,0,1}, 5683},
        port: 5683,
        qs: "who=world",
        socket: "socket"
      }
  """
  def build(%Message{options: options} = message, socket, address, port) do
    ip_string = Enum.join(Tuple.to_list(address), ".")

    # TODO: defstruct?
    %{
      method: message |> method,
      path: options["Uri-Path"],
      host: options["Uri-Host"],
      port: port,
      qs: options["Uri-Query"],
      headers: options,
      peer: {address, port},
      socket: socket
    }
  end

  defp method(%Message{code_class: 0, code_detail: code_detail}), do: @methods[{0, code_detail}]
end
