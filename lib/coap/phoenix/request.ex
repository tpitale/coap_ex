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
    {0,01} => :get,
    {0,02} => :post,
    {0,03} => :put,
    {0,04} => :delete
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
      iex>   options: %{uri_path: ["api", ""], uri_query: ["who=world", "what=hello"], uri_host: "localhost"},
      iex>   payload: "payload"
      iex> }
      iex> CoAP.Phoenix.Request.build(message, "socket", {127,0,0,1}, 5683)
      %{
        headers: %{
          uri_path: ["api", ""],
          uri_query: ["who=world", "what=hello"],
          uri_host: "localhost"
        },
        host: "localhost",
        method: :put,
        path: "api/",
        peer: {{127,0,0,1}, 5683},
        port: 5683,
        qs: "who=world&what=hello",
        socket: "socket"
      }
  """
  def build(%Message{options: options} = message, socket, address, port, config \\ %{}) do
    ip_string = Enum.join(Tuple.to_list(address), ".")

    # TODO: defstruct?
    %{
      method: message |> method,
      path: options[:uri_path] |> Enum.join("/"),
      host: options[:uri_host] || config[:host],
      port: port,
      qs: options[:uri_query] |> Enum.join("&"),
      headers: options,
      peer: {address, port},
      socket: socket
    }
  end

  defp method(%Message{code_class: 0, code_detail: code_detail}), do: @methods[{0, code_detail}]
end
