defmodule CoAP.Client.RequestTest do
  use ExUnit.Case
  doctest CoAP.Message

  # import ExUnitProperties

  alias CoAP.Client.Request
  # alias CoAP.Message

  describe "uri-host option" do
    test "litteral IPv4 - no option" do
      {:ok, {_uri, m}} = Request.build(:get, "coap://1.2.3.4/resource")
      refute Map.has_key?(m.options, :uri_host)
    end

    test "litteral IPv6 - no option" do
      {:ok, {_uri, m}} = Request.build(:get, "coap://[::1]/resource")
      refute Map.has_key?(m.options, :uri_host)
    end

    test "hostname" do
      {:ok, {_uri, m}} = Request.build(:get, "coap://example.org/resource")
      assert %{uri_host: "example.org"} = m.options
    end

    test "user override" do
      {:ok, {_uri, m}} =
        Request.build(:get, {"coap://example.org/resource", uri_host: "svc.example.org"})

      assert %{uri_host: "svc.example.org"} = m.options
    end

    test "user provided" do
      {:ok, {_uri, m}} =
        Request.build(:get, {"coap://1.2.3.4/resource", uri_host: "svc.example.org"})

      assert %{uri_host: "svc.example.org"} = m.options
    end
  end

  describe "uri-port option" do
    test "no uri-port option" do
      {:ok, {_uri, m}} = Request.build(:get, "coap://example.org:8080/resource")
      refute Map.has_key?(m.options, :uri_port)
    end

    test "user provided" do
      {:ok, {_uri, m}} = Request.build(:get, {"coap://example.org:8080/resource", uri_port: 8181})
      assert %{uri_port: 8181} = m.options
    end
  end
end
