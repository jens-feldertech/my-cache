defmodule MyCacheTest do
  use ExUnit.Case, async: true
  doctest MyCache

  describe "register_function/4" do
    test "returns :ok if key does not exist in cache" do
      response = MyCache.register_function(fn -> {:ok, 1} end, :task, 4000, 2000)
      assert response == :ok
    end

    test "returns {:error, :already_registered} if key exists in cache" do
      key = gen_key()

      MyCache.register_function(fn -> {:ok, 1} end, key, 4000, 2000)

      result = MyCache.register_function(fn -> {:ok, 2} end, key, 4000, 2000)

      assert result == {:error, :already_registered}
    end

    test "returns {:error, :wrong_arguments} if arguments are wrong" do
      non_zero_arity_function = MyCache.register_function(fn x -> {:ok, x} end, :task, 4000, 2000)
      negative_integer_ttl = MyCache.register_function(fn -> {:ok, 1} end, :task, -4000, 2000)

      negative_integer_interval =
        MyCache.register_function(fn -> {:ok, 1} end, :task, 4000, -2000)

      interval_greater_than_ttl = MyCache.register_function(fn -> {:ok, 1} end, :task, 1000, 5000)
      non_integer_ttl = MyCache.register_function(fn -> {:ok, 1} end, :task, "4000", 2000)
      non_integer_interval = MyCache.register_function(fn -> {:ok, 1} end, :task, 4000, "2000")

      assert non_zero_arity_function == {:error, :wrong_arguments}
      assert negative_integer_ttl == {:error, :wrong_arguments}
      assert negative_integer_interval == {:error, :wrong_arguments}
      assert interval_greater_than_ttl == {:error, :wrong_arguments}
      assert non_integer_ttl == {:error, :wrong_arguments}
      assert non_integer_interval == {:error, :wrong_arguments}
    end

    test "registeres function ttl and value in cache under key" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 10000, 5000)

      record =
        :sys.get_state(MyCache)
        |> Map.get(key)

      refute record == nil
      assert record == %{ttl: 10000, value: nil}
    end

    test "Task updates cached value if fun returns {:ok, value}" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 5000, 1000)

      :timer.sleep(1020)

      record =
        :sys.get_state(MyCache)
        |> Map.get(key)

      assert record.value == 1
    end

    test "Task doesn't cache value if fun returns {:error, value}" do
      key = gen_key()
      MyCache.register_function(fn -> {:error, nil} end, key, 5000, 1000)

      :timer.sleep(2000)
      state = :sys.get_state(MyCache)
      record = Map.get(state, key)

      assert record.value == nil
    end

    test "Starts Task for registered function and reschedules it after refresh interval" do
      key = gen_key()

      MyCache.register_function(
        fn ->
          {:ok, Enum.random(1..100)}
        end,
        key,
        5000,
        1000
      )

      :timer.sleep(1020)

      record_1 =
        :sys.get_state(MyCache)
        |> Map.get(key)

      :timer.sleep(1000)

      record_2 =
        :sys.get_state(MyCache)
        |> Map.get(key)

      refute record_1.value == record_2.value
    end

    test "schedules tasks concurrently" do
      key_1 = gen_key()
      key_2 = gen_key()
      refresh_interval = 1000

      MyCache.register_function(fn -> {:ok, 1} end, key_1, 5000, refresh_interval)
      MyCache.register_function(fn -> {:ok, 2} end, key_2, 5000, refresh_interval)

      :timer.sleep(1020)

      records =
        :sys.get_state(MyCache)
        |> Map.take([key_1, key_2])

      assert records[key_1].value == 1
      assert records[key_2].value == 2
    end

    # TODO Update test
    test "Remove function after ttl has expired" do
      key = gen_key()
      MyCache.register_function(fn -> {:error, System.monotonic_time()} end, key, 2000, 1000)

      :timer.sleep(5000)

      record =
        :sys.get_state(MyCache)
        |> Map.get(key)

      assert record == nil
    end

    test "ttl is reduced after {:error, reason} is returned" do
      key = gen_key()
      MyCache.register_function(fn -> {:error, "error"} end, key, 2000, 1000)

      :timer.sleep(1020)

      record =
        :sys.get_state(MyCache)
        |> Map.get(key)

      assert record.ttl < 2000
    end

    test "ttl is refreshed after {:ok, value} is returned" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 2000, 1000)

      :timer.sleep(1020)

      record =
        :sys.get_state(MyCache)
        |> Map.get(key)

      assert record.ttl == 2000
    end

    test "remove function from cache after illegal return value" do
      key = gen_key()
      MyCache.register_function(fn -> "return" end, key, 2000, 1000)

      :timer.sleep(1020)

      record =
        :sys.get_state(MyCache)
        |> Map.get(key)

      assert record == nil
    end
  end

  describe "get/3" do
    test "returns {:error, :timeout} if function is cached but value is not computed yet" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 6000, 3000)
      response = MyCache.get(key, 2000)
      assert response == {:error, :timeout}
    end

    test "If the value for `key` is stored in the cache, the value is returned
    immediately" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 6000, 3000)

      :timer.sleep(2000)
      response = MyCache.get(key, 2000)

      assert response == 1
    end

    test "If a recomputation of the function is in progress, the last stored value
    is returned" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, Enum.random(1..1000)} end, key, 10000, 2000)

      :timer.sleep(3000)
      response_1 = MyCache.get(key, 1)

      response_2 = MyCache.get(key, 1)

      assert response_1 == response_2
    end

    test "Return {:error, :timeout} if the value for key is not stored after timeout and a computation is in progress" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 10000, 5000)

      response = MyCache.get(key, 2000)

      assert response == {:error, :timeout}
    end

    test "Return value if the value for key is stored after timeout" do
      key = gen_key()
      MyCache.register_function(fn -> {:ok, 1} end, key, 10000, 5000)

      response = MyCache.get(key, 6000)

      assert response == 1
    end

    test "If key is not associated with any function, return {:error, :not_registered}" do
      key = gen_key()

      response = MyCache.get(key, 6000)

      assert response == {:error, :not_registered}
    end
  end

  defp gen_key do
    :crypto.strong_rand_bytes(8)
  end
end
