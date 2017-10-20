defmodule Gateway.ProxyTest do
  @moduledoc false
  use ExUnit.Case, async: true
  require Logger
  alias Gateway.Proxy
  import Gateway.Proxy, only: [
    list_apis: 1,
    get_api: 2,
    add_api: 3,
    update_api: 3,
    delete_api: 2,
    handle_join_api: 3,
    handle_leave_api: 3,
  ]

  @mock_api %{ # TODO: PLAY WITH DEFAULT VALUES
    "auth" => %{
      "header_name" => "",
      "query_name" => "",
      "use_header" => false,
      "use_query" => false
    },
    "auth_type" => "none",
    "id" => "new-service",
    "name" => "new-service",
    "proxy" => %{
      "port" => 4444,
      "target_url" => "API_HOST",
      "use_env" => true
    },
    "version_data" => %{
      "default" => %{
        "endpoints" => [
          %{
            "id" => "get-movies",
            "method" => "GET",
            "not_secured" => true,
            "path" => "/myapi/movies"
          }
        ]
      }
    },
    "versioned" => false
  }

  setup [:with_tracker_mock_proxy]

  test "list_apis should return list with 2 API definitions", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

    assert proxy |> list_apis |> length == 2
    assert ctx.tracker |> Stubr.called_twice?(:track)
    assert ctx.tracker |> Stubr.called_once?(:list_by_node)
  end

  test "get_api should return nil for non-existent API definition", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)
  
    assert proxy |> get_api("random-service")
    assert ctx.tracker |> Stubr.called_once?(:find_by_node)
  end

  test "add_api should start tracking new API", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)
  
    refute proxy |> get_api("new-service")
    assert ctx.tracker |> Stubr.called_twice?(:track)
    assert ctx.tracker |> Stubr.called_once?(:find_by_node)
  
    {:ok, _response} = proxy |> add_api("new-service", @mock_api)
  
    assert proxy |> get_api("new-service")
    assert ctx.tracker |> Stubr.called_thrice?(:track)
    assert ctx.tracker |> Stubr.called_twice?(:find_by_node)
  end

  test "add_api with existing ID should return error", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)
  
    {:error, :already_tracked} = proxy |> add_api("random-service", @mock_api)
    assert ctx.tracker |> Stubr.called_thrice?(:track)
  end

  test "update_api should update existing API", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)
  
    existing_api =
      proxy
      |> get_api("random-service")
      |> elem(1)
    
    assert existing_api["name"] == "random-service"
  
    updated_existing_api =
      existing_api
      |> Map.put("name", "updated-service")
    proxy |> update_api("random-service", updated_existing_api)
  
    new_api =
      proxy
      |> get_api("random-service")
      |> elem(1)
  
    assert new_api["name"] == "updated-service"
    assert ctx.tracker |> Stubr.called_once?(:update)
  end

  test "delete_api should untrack API", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)
    
    assert proxy |> get_api("random-service")
  
    proxy |> delete_api("random-service")
  
    refute proxy |> get_api("random-service")
    assert ctx.tracker |> Stubr.called_once?(:untrack)
  end

  test "handle_join_api should track new API", ctx do
    {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

    proxy |> handle_join_api("new-service", @mock_api)

    :timer.sleep(50)
    assert proxy |> get_api("new-service")
    assert ctx.tracker |> Stubr.called_thrice?(:track)
    refute ctx.tracker |> Stubr.called?(:update)
  end

  describe "handle_join_api receiving existing API" do
    test "should skip API when it has out of date ref_number", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      older_api =
        proxy
        |> get_api("random-service")
        |> elem(1)
        |> Map.put("ref_number", -1)

      assert ctx.tracker |> Stubr.called_twice?(:track)
      proxy |> handle_join_api("random-service", older_api)

      current_api =
        proxy
        |> get_api("random-service")
        |> elem(1)

      :timer.sleep(50)
      assert current_api["ref_number"] == 0
      refute ctx.tracker |> Stubr.called?(:update)
      assert ctx.tracker |> Stubr.called_twice?(:track)
    end

    test "should update API when it has more recent ref_number", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      newer_api =
        proxy
        |> get_api("random-service")
        |> elem(1)
        |> Map.put("ref_number", 1)

      assert ctx.tracker |> Stubr.called_twice?(:track)
      proxy |> handle_join_api("random-service", newer_api)

      current_api =
        proxy
        |> get_api("random-service")
        |> elem(1)

      :timer.sleep(50)
      assert current_api["ref_number"] == 1
      assert ctx.tracker |> Stubr.called_once?(:update)
      assert ctx.tracker |> Stubr.called_twice?(:track)
    end

    test "with same ref_number and equal data should skip API", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      same_api =
        proxy
        |> get_api("random-service")
        |> elem(1)

      assert ctx.tracker |> Stubr.called_twice?(:track)
      proxy |> handle_join_api("random-service", same_api)

      current_api =
        proxy
        |> get_api("random-service")
        |> elem(1)

      :timer.sleep(50)
      assert current_api["ref_number"] == 0
      refute ctx.tracker |> Stubr.called?(:update)
      assert ctx.tracker |> Stubr.called_twice?(:track)
    end
  end

  describe "handle_join_api receiving existing API with same ref_number and different data" do

    test "on less than 1/2 nodes should skip API", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      node2_api = @mock_api |> Map.put("node_name", :node2@node2)
      node3_api = @mock_api |> Map.put("node_name", :node3@node3)

      proxy |> add_api("new-service", @mock_api)
      proxy |> add_api("new-service", node2_api)
      proxy |> add_api("new-service", node3_api)
      assert ctx.tracker |> Stubr.call_count(:track) == 5

      different_api =
        @mock_api
        |> Map.put("ref_number", 0)
        |> Map.put("name", "new_name")
      proxy |> handle_join_api("new-service", different_api)

      :timer.sleep(50)
      refute ctx.tracker |> Stubr.called?(:update)
      assert ctx.tracker |> Stubr.call_count(:track) == 5
    end

    test "on more than 1/2 nodes should update API", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      different_api =
        @mock_api
        |> Map.put("name", "new_name")
        |> Map.put("ref_number", 0)
      node2_api = different_api |> Map.put("node_name", :node2@node2)
      node3_api = different_api |> Map.put("node_name", :node3@node3)

      proxy |> add_api("new-service", @mock_api)
      proxy |> add_api("new-service", node2_api)
      proxy |> add_api("new-service", node3_api)
      assert ctx.tracker |> Stubr.call_count(:track) == 5

      proxy |> handle_join_api("new-service", different_api)

      current_api =
        proxy
        |> get_api("new-service")
        |> elem(1)

      :timer.sleep(50)
      assert current_api["ref_number"] == 0
      assert current_api["name"] == "new_name"
      assert ctx.tracker |> Stubr.called_once?(:update)
      assert ctx.tracker |> Stubr.call_count(:track) == 5
    end

    test "on exactly 1/2 nodes, but old timestamp should skip API", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      old_timestamp = Timex.now |> Timex.shift(minutes: -3)
      different_api =
        @mock_api
        |> Map.put("ref_number", 0)
        |> Map.put("name", "new_name")
        |> Map.put("node_name", :differentnode@differenthost)
        |> Map.put("timestamp", old_timestamp)

      proxy |> add_api("new-service", @mock_api)
      proxy |> add_api("new-service", different_api)
      assert ctx.tracker |> Stubr.call_count(:track) == 4

      proxy |> handle_join_api("new-service", different_api)

      :timer.sleep(50)
      refute ctx.tracker |> Stubr.called?(:update)
      assert ctx.tracker |> Stubr.call_count(:track) == 4
    end

    test "on exactly 1/2 nodes and newer timestamp should update API", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      new_timestamp = Timex.now |> Timex.shift(minutes: +3)
      different_api =
        @mock_api
        |> Map.put("ref_number", 0)
        |> Map.put("name", "new_name")
        |> Map.put("node_name", :differentnode@differenthost)
        |> Map.put("timestamp", new_timestamp)

      proxy |> add_api("new-service", @mock_api)
      proxy |> add_api("new-service", different_api)
      assert ctx.tracker |> Stubr.call_count(:track) == 4

      proxy |> handle_join_api("new-service", different_api)

      :timer.sleep(50)
      assert ctx.tracker |> Stubr.call_count(:track) == 4
      assert ctx.tracker |> Stubr.called_once?(:update)
    end
  end

  describe "handle_leave_api comparing APIs within same node" do
    test "should skip untrack if API doesn't exist", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      origin_api = @mock_api |> Map.put("node_name", :nonode@nohost)
      proxy |> handle_leave_api("new-service", origin_api)

      :timer.sleep(50)
      refute ctx.tracker |> Stubr.called?(:untrack)
    end

    test "should skip untrack if compared APIs have different phx_ref", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      different_origin_api =
        proxy
        |> get_api("random-service")
        |> elem(1)
        |> Map.put(:phx_ref, "ref2")

      proxy |> handle_leave_api("random-service", different_origin_api)

      :timer.sleep(50)
      refute ctx.tracker |> Stubr.called?(:untrack)
    end

    test "should untrack if compared APIs have same phx_ref", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      origin_api =
        proxy
        |> get_api("random-service")
        |> elem(1)

      proxy |> handle_leave_api("random-service", origin_api)

      :timer.sleep(50)
      assert ctx.tracker |> Stubr.called_once?(:untrack)
    end
  end

  describe "handle_leave_api comparing APIs from different node" do
    test "should untrack origin API if foreign API doesn't exist", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      different_node_api =
        proxy
        |> get_api("random-service")
        |> elem(1)
        |> Map.put("node_name", :node2@node2)
      proxy |> handle_leave_api("random-service", different_node_api)

      :timer.sleep(50)
      assert ctx.tracker |> Stubr.called_once?(:untrack)
    end

    test "should untrack origin API if compared APIs have same phx_ref", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      different_node_api =
        proxy
        |> get_api("random-service")
        |> elem(1)
        |> Map.put("node_name", :node2@node2)

      proxy |> add_api("new-service", different_node_api)
      proxy |> handle_leave_api("new-service", different_node_api)

      :timer.sleep(50)
      assert ctx.tracker |> Stubr.called_once?(:untrack)
    end

    test "should skip untrack if compared APIs have different phx_ref", ctx do
      {:ok, proxy} = Proxy.start_link(ctx.tracker, name: nil)

      different_node_api =
        proxy
        |> get_api("random-service")
        |> elem(1)
        |> Map.put("node_name", :node2@node2)

      proxy |> add_api("new-service", different_node_api)

      different_node_different_api = different_node_api |> Map.put(:phx_ref, "ref2")
      proxy |> handle_leave_api("new-service", different_node_different_api)

      :timer.sleep(50)  
      refute ctx.tracker |> Stubr.called?(:untrack)
    end
  end

  defp with_tracker_mock_proxy(_ctx) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    tracker = Stubr.stub!([
        track: fn id, api ->
          Logger.debug "Tracker Stub :track id=#{inspect id} api=#{inspect api}"
          # Mimic the "cannot track more than once" behaviour:
          already_tracked? = Agent.get(agent, fn
            list -> list |> Enum.find(fn {key, meta} ->
              key == id && meta["node_name"] == api["node_name"]
            end)
          end) != nil
          if already_tracked? do
            {:error, :already_tracked}
          else
            Agent.update(agent, fn
              list ->
                api_with_ref = api |> Map.put(:phx_ref, "some_phx_ref")
                [{id, api_with_ref} | list]
            end)
            {:ok, 'some_phx_ref'}
          end
        end,
        untrack: fn id ->
          Logger.debug "Tracker Stub :untrack id=#{inspect id}"
          Agent.update(agent, fn
            list -> list |> Enum.filter(fn {key, _} -> key != id end)
          end)
          :ok
        end,
        update: fn id, api ->
          Logger.debug "Tracker Stub :update id=#{inspect id} api=#{inspect api}"
          Agent.update(agent, fn
            list ->
              list
              |> Enum.filter(fn {key, meta} ->
                key != id || meta["node_name"] != :nonode@nohost
              end)
              |> Enum.concat([{id, api}])
          end)
          {:ok, 'some_phx_ref'}
        end,
        list_all: fn ->
          Logger.debug "Tracker Stub :list"
          Agent.get(agent, fn
            list -> list
          end)
        end,
        list_by_node: fn node_name ->
          Logger.debug "Tracker Stub :list"
          Agent.get(agent, fn
            list -> list |> Enum.filter(fn {_key, meta} -> meta["node_name"] == node_name end)
          end)
        end,
        find_by_node: fn id, node_name -> # was _node_name
          Logger.debug "Tracker Stub :find id=#{inspect id}"
          Agent.get(agent, fn
            list -> list |> Enum.find(fn {key, meta} ->
              key == id && meta["node_name"] == node_name
            end)
          end)
        end,
        find_all: fn id ->
          Logger.debug "Tracker Stub :find_all id=#{inspect id}"
          Agent.get(agent, fn
            list -> list |> Enum.filter(fn {key, _meta} -> key == id end)
          end)
        end,
      ],
      behaviour: Gateway.ApiProxy.Tracker.TrackerBehaviour,
      call_info: true,
    )
    [tracker: tracker]
  end

end
