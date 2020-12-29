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
  @spec build(method(), request(), boolean()) :: {:ok, {URI.t(), Message.t()}} | {:error, term}
  def build(method, url, con? \\ true)

  def build(method, url, con?) when is_binary(url), do: build(method, {url, %{}, <<>>}, con?)

  def build(method, {url, options}, con?), do: build(method, {url, options, <<>>}, con?)

  def build(method, {url, options, payload}, con?) do
    %{errors: []}
    |> parse_uri(url)
    |> check_uri_protocol()
    |> normalize_uri_port()
    |> cast_method(method)
    |> add_uri_options(options)
    |> case do
      %{
        errors: [],
        uri: uri,
        options: options,
        method_code_class: code_class,
        method_code_detail: code_detail
      } ->
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

      %{errors: errors} ->
        {:error, errors}
    end
  end

  @doc """
  Returns peer out of URI
  """
  @spec peer(URI.t()) :: {binary(), integer()}
  def peer(%URI{host: host, port: port}), do: {host, port}

  ###
  ### Priv
  ###
  defp parse_uri(s, url) do
    Map.put(s, :uri, URI.parse(url))
  rescue
    _ -> add_error(s, "invalid url")
  end

  defp check_uri_protocol(%{uri: %URI{scheme: "coap"}} = s), do: s
  defp check_uri_protocol(%{uri: %URI{scheme: "coaps"}} = s), do: s

  defp check_uri_protocol(%{uri: %URI{scheme: nil}} = s),
    do: add_error(s, "missing protocol")

  defp check_uri_protocol(%{errors: []} = s),
    do: add_error(s, "missing protocol: #{s.uri.scheme}")

  defp check_uri_protocol(s), do: s

  defp normalize_uri_port(%{uri: %URI{scheme: "coap", port: nil} = uri} = s),
    do: %{s | uri: %URI{uri | port: @default_port}}

  defp normalize_uri_port(%{uri: %URI{scheme: "coaps", port: nil} = uri} = s),
    do: %{s | uri: %URI{uri | port: @default_port}}

  defp normalize_uri_port(s), do: s

  defp cast_method(s, method) do
    case Message.encode_method(method) do
      {code_class, code_detail} ->
        Map.merge(s, %{method_code_class: code_class, method_code_detail: code_detail})

      nil ->
        add_error(s, "invalid method #{inspect(method)}")
    end
  end

  defp add_uri_options(%{errors: [], uri: uri} = s, options) do
    options = uri |> Map.from_struct() |> Enum.reduce(Enum.into(options, %{}), &uri_options/2)
    Map.put(s, :options, options)
  end

  defp add_uri_options(s, _options), do: s

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

  defp uri_options({:path, path}, opts) do
    path
    |> String.split("/", trim: true)
    |> case do
      [] -> opts
      fragments -> Map.put(opts, :uri_path, fragments)
    end
  end

  defp uri_options(_, opts), do: opts

  defp add_error(s, err) do
    Map.update!(s, :errors, &[err | &1])
  end
end
