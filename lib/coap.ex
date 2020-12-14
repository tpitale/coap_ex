defmodule CoAP do
  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: CoAP.SocketServerSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: CoAP.HandlerSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: CoAP.ConnectionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
