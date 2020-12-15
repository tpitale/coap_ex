defmodule CoAP.Util do
  @moduledoc false

  @doc false
  @spec resolve_ip(URI.t() | String.Chars.t()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def resolve_ip(%URI{host: host}), do: resolve_ip(host)

  def resolve_ip(host) do
    '#{host}'
    |> :inet.getaddr(:inet)
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, {:invalid_host, reason}}
    end
  end
end
