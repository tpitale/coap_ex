defmodule CoAP.Client.Request do
  @moduledoc """
  Creates request data types
  """

  alias CoAP.Message

  @type method() :: Message.request_method()
  @type coap_options :: Enumerable.t()
  @type payload :: binary()
  @type url() :: binary()
  @type request() :: url() | {url(), coap_options()} | {url(), coap_options(), payload()}
  @type t :: request()

  @default_port 5683

  @doc """
  Creates request message and URI
  """
  @spec build(method(), request(), boolean()) :: {:ok, {URI.t(), Message.t()}}
  def build(method, url, con? \\ true)

  def build(method, url, con?) when is_binary(url), do: build(method, {url, %{}, <<>>}, con?)

  def build(method, {url, options}, con?), do: build(method, {url, options, <<>>}, con?)

  def build(method, {url, options, payload}, con?) do
    uri = url |> URI.parse() |> normalize_port()
    {code_class, code_detail} = Message.encode_method(method)
    options = uri |> Map.from_struct() |> Enum.reduce(Enum.into(options, %{}), &uri_options/2)

    message = %Message{
      request: true,
      type: if(con?, do: :con, else: :non),
      method: method,
      token: :crypto.strong_rand_bytes(4),
      code_class: code_class,
      code_detail: code_detail,
      payload: payload,
      options: options
    }

    {:ok, {uri, message}}
  end

  ###
  ### Priv
  ###
  defp normalize_port(%URI{scheme: "coap", port: nil} = uri), do: %URI{uri | port: @default_port}
  defp normalize_port(%URI{scheme: "coaps", port: nil} = uri), do: %URI{uri | port: @default_port}
  defp normalize_port(%URI{} = uri), do: uri

  defp uri_options({:host, host}, opts) do
    case :inet.parse_address('#{host}') do
      {:ok, _} ->
        # hostname is a litteral IP, no option
        opts

      {:error, :einval} ->
        # hostname is a (fq)dn, add uri-host option
        Map.put_new(opts, :uri_host, host)
    end
  end

  defp uri_options(_, opts), do: opts
end
