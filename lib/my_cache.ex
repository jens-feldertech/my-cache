defmodule MyCache do
  use GenServer

  require Logger

  alias MyCache.Function
  alias MyCache.TaskSupervisor

  @initial_state %{}

  @type result ::
          {:ok, any()}
          | {:error, :timeout}
          | {:error, :not_registered}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, @initial_state, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, @initial_state}
  end

  @doc ~s"""
  Registers a function that will be computed periodically to update the cache.
  Arguments:
    - `fun`: a 0-arity function that computes the value and returns either
      `{:ok, value}` or `{:error, reason}`.
    - `key`: associated with the function and is used to retrieve the stored
    value.
    - `ttl` ("time to live"): how long (in milliseconds) the value is stored
      before it is discarded if the value is not refreshed.
    - `refresh_interval`: how often (in milliseconds) the function is
      recomputed and the new value stored. `refresh_interval` must be strictly
      smaller than `ttl`. After the value is refreshed, the `ttl` counter is
      restarted.
  The value is stored only if `{:ok, value}` is returned by `fun`. If `{:error,
  reason}` is returned, the value is not stored and `fun` must be retried on
  the next run.
  """
  @spec register_function(
          fun :: (() -> {:ok, any()} | {:error, any()}),
          key :: any,
          ttl :: non_neg_integer(),
          refresh_interval :: non_neg_integer()
        ) :: :ok | {:error, :already_registered}
  def register_function(fun, key, ttl, refresh_interval)
      when is_function(fun, 0) and is_integer(ttl) and ttl > 0 and
             is_integer(refresh_interval) and refresh_interval > 0 and
             refresh_interval < ttl do
    if not key_exists?(key) do
      # Store the function in the cache with nil value
      store_function(key, nil, ttl)

      # Create a struct with the function and the arguments
      # Add initial start time in system time to be used later in ttl calculation
      # Schedule the first computation
      Function.create_struct(fun, key, ttl, refresh_interval)
      |> add_start_time()
      |> schedule_next_computation()

      :ok
    else
      {:error, :already_registered}
    end
  end

  # If the function is called with wrong arguments, return {:error, :wrong_arguments}
  def register_function(_fun, _key, _ttl, _refresh_interval) do
    {:error, :wrong_arguments}
  end

  @doc ~s"""
  Get the value associated with `key`.
  Details:
    - If the value for `key` is stored in the cache, the value is returned
      immediately.
    - If a recomputation of the function is in progress, the last stored value
      is returned.
    - If the value for `key` is not stored in the cache but a computation of
      the function associated with this `key` is in progress, wait up to
      `timeout` milliseconds. If the value is computed within this interval,
      the value is returned. If the computation does not finish in this
      interval, `{:error, :timeout}` is returned.
    - If `key` is not associated with any function, return `{:error,
      :not_registered}`
  """
  @spec get(any(), non_neg_integer(), Keyword.t()) :: result
  def get(key, timeout \\ 30_000, _opts \\ []) when is_integer(timeout) and timeout > 0 do
    case get_cache_record(key) do
      nil -> {:error, :not_registered}
      %{value: nil} -> wait_on_value(key, timeout)
      %{value: value} -> value
    end
  end

  @impl GenServer
  def handle_call({:get_cache_record, key}, _from, cache) do
    {:reply, Map.get(cache, key), cache}
  end

  def handle_call({:key_exists, key}, _from, cache) do
    {:reply, Map.has_key?(cache, key), cache}
  end

  @impl GenServer
  def handle_cast({:store_function, key, value, ttl}, cache) do
    updated_cache = Map.put_new(cache, key, %{value: value, ttl: ttl})

    {:noreply, updated_cache}
  end

  # Start the task under Supervisor and update functon struct with new value
  @impl GenServer
  def handle_info({:start_task, task}, cache) do
    Task.Supervisor.async_nolink(TaskSupervisor, fn ->
      {:ok, %{task | value: task.fun.()}}
    end)

    {:noreply, cache}
  end

  # Receives message from TaskSupervisor when the task is finished

  # If the fun returns {:ok, value}:
  # - store the value in the cache and reset ttl
  # - schedule the next computation
  # - reset the last start time to never expire function if {:ok, value} is returned
  # - remove the task from the monitor list to avoid DOWN message
  def handle_info({task_ref, {:ok, function = %{value: {:ok, value}}}}, cache) do
    Process.demonitor(task_ref, [:flush])

    updated_cache =
      cache
      |> put_in([function.key, :value], value)
      |> put_in([function.key, :ttl], function.ttl)

    %{function | last_started_at: System.monotonic_time(:millisecond)}
    |> schedule_next_computation()

    {:noreply, updated_cache}
  end

  # If the fun returns {:error, reason}:
  # - decrease ttl
  # - if ttl is expired, schedule the next computation and update function ttl in cache
  # - if ttl is expired, remove the record from the cache
  # - remove the task from the monitor list to avoid DOWN message
  def handle_info({task_ref, {:ok, function = %{value: {:error, _reason}}}}, cache) do
    Process.demonitor(task_ref, [:flush])

    decreased_ttl = decrease_ttl(function)

    if not ttl_expired?(decreased_ttl) do
      # TODO has to keep previous value in the cache
      updated_cache = put_in(cache, [function.key, :ttl], decreased_ttl)

      schedule_next_computation(function)
      {:noreply, updated_cache}
    else
      remove_cached_record(function.key, function.ttl)
      {:noreply, cache}
    end
  end

  # If the fun returns anything else, remove the record from the cache and log error
  # remove the task from the monitor list to avoid DOWN message
  def handle_info({task_ref, {:ok, function}}, cache) do
    Process.demonitor(task_ref, [:flush])

    Logger.error("
    Function #{function.key} returned an invalid value.
    {:ok, value} or {:error, reason} duple is expected, got: #{function.value}
    Removing the record from the cache
    ")

    remove_cached_record(function.key)
    {:noreply, cache}
  end

  def handle_info({:remove_cached_record, key}, cache) do
    updated_cache = Map.delete(cache, key)

    {:noreply, updated_cache}
  end

  # Helper functions

  defp wait_on_value(key, timeout) do
    case get_cache_record(key, timeout) do
      %{value: nil} -> {:error, :timeout}
      %{value: value} -> value
    end
  end

  defp get_cache_record(key, timeout \\ 0) do
    :timer.sleep(timeout)
    GenServer.call(MyCache, {:get_cache_record, key})
  end

  defp remove_cached_record(key, interval \\ 0) do
    Process.send_after(self(), {:remove_cached_record, key}, interval)
  end

  defp schedule_next_computation(function) do
    Process.send_after(MyCache, {:start_task, function}, function.refresh_interval)
  end

  defp key_exists?(key) do
    GenServer.call(MyCache, {:key_exists, key})
  end

  defp add_start_time(function) do
    %{function | last_started_at: System.monotonic_time(:millisecond)}
  end

  defp store_function(key, value, ttl) do
    GenServer.cast(MyCache, {:store_function, key, value, ttl})
  end

  defp decrease_ttl(function) do
    function.ttl - abs(function.last_started_at - System.monotonic_time(:millisecond))
  end

  defp ttl_expired?(ttl), do: ttl <= 0
end
