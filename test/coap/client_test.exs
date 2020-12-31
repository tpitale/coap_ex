defmodule CoAP.ClientTest do
  use CoAP.Test.Support.DataCase

  doctest CoAP.Client

  alias CoAP.Client
  alias CoAP.Message
  alias CoAP.Test.Support.LocalAdapter

  test "get - confirmable, piggybacked response" do
    server = fn
      %Message{type: :con, code_class: 0, code_detail: 1} = m, cb ->
        cb.(%Message{m | type: :ack, code_class: 2, code_detail: 5, payload: <<"response">>})
    end

    response =
      Client.get("coap://example.org/api", socket_adapter: LocalAdapter, socket_opts: server)

    assert %Message{code_class: 2, code_detail: 5, payload: <<"response">>} = response
  end

  test "get - confirmable, separate con response" do
    server = fn
      %Message{type: :con, code_class: 0, code_detail: 1} = m, cb ->
        cb.(%Message{m | type: :ack, payload: <<>>})
        :timer.sleep(100)
        cb.(%Message{m | type: :con, code_class: 2, code_detail: 5, payload: <<"response">>})
    end

    response =
      Client.get("coap://example.org/api", socket_adapter: LocalAdapter, socket_opts: server)

    assert %Message{code_class: 2, code_detail: 5, payload: <<"response">>} = response
  end

  test "get - confirmable, separate non response" do
    server = fn
      %Message{type: :con, code_class: 0, code_detail: 1} = m, cb ->
        cb.(%Message{m | type: :ack, payload: <<>>})
        :timer.sleep(100)
        cb.(%Message{m | type: :non, code_class: 2, code_detail: 5, payload: <<"response">>})
    end

    response =
      Client.get("coap://example.org/api", socket_adapter: LocalAdapter, socket_opts: server)

    assert %Message{code_class: 2, code_detail: 5, payload: <<"response">>} = response
  end

  test "get - non confirmable" do
    server = fn
      %Message{type: :non, code_class: 0, code_detail: 1} = m, cb ->
        cb.(%Message{m | type: :non, code_class: 2, code_detail: 5, payload: <<"response">>})
    end

    response =
      Client.request(:get, "coap://example.org/api",
        confirmable: false,
        socket_adapter: LocalAdapter,
        socket_opts: server
      )

    assert %Message{code_class: 2, code_detail: 5, payload: <<"response">>} = response
  end

  test "get - confirmable, separate response, timeout" do
    server = fn
      %Message{type: :con, code_class: 0, code_detail: 1} = m, cb ->
        cb.(%Message{m | type: :ack, payload: <<>>})
    end

    response =
      Client.get("coap://example.org/api",
        timeout: 50,
        socket_adapter: LocalAdapter,
        socket_opts: server
      )

    assert {:error, {:timeout, :await_response}} = response
  end

  test "get - confirmable, timeout" do
    server = fn _m, _cb -> :ok end

    response =
      Client.get("coap://example.org/api",
        timeout: 50,
        socket_adapter: LocalAdapter,
        socket_opts: server
      )

    assert {:error, {:timeout, :await_response}} = response
  end

  test "get - non confirmable, timeout" do
    server = fn _, _ -> :ok end

    response =
      Client.request(:get, "coap://example.org/api",
        timeout: 100,
        confirmable: false,
        socket_adapter: LocalAdapter,
        socket_opts: server
      )

    assert {:error, {:timeout, :await_response}} = response
  end

  property "get - large response payload" do
    check all(response_payload <- binary(length: 1024)) do
      server = fn
        %Message{type: :con, code_class: 0, code_detail: 1} = m, cb ->
          cb.(%Message{m | type: :ack, code_class: 2, code_detail: 5, payload: response_payload})
      end

      response =
        Client.get("coap://example.org/api", socket_adapter: LocalAdapter, socket_opts: server)

      assert %Message{code_class: 2, code_detail: 5, payload: payload} = response
      assert 1024 == byte_size(payload)
    end
  end

  property "post - large payload" do
    check all(payload <- binary(length: 1024)) do
      server = fn
        %Message{type: :con, code_class: 0, code_detail: 2} = m, cb ->
          cb.(%Message{m | type: :ack, code_class: 2, code_detail: 4})
      end

      response =
        Client.post("coap://example.org/api", payload,
          socket_adapter: LocalAdapter,
          socket_opts: server
        )

      assert %Message{code_class: 2, code_detail: 4, payload: payload} = response
      assert 1024 == byte_size(payload)
    end
  end

  property "put - large payload" do
    check all(payload <- binary(length: 1024)) do
      server = fn
        %Message{type: :con, code_class: 0, code_detail: 3} = m, cb ->
          cb.(%Message{m | type: :ack, code_class: 2, code_detail: 1})
      end

      response =
        Client.put("coap://example.org/api", payload,
          socket_adapter: LocalAdapter,
          socket_opts: server
        )

      assert %Message{code_class: 2, code_detail: 1, payload: payload} = response
      assert 1024 == byte_size(payload)
    end
  end
end
