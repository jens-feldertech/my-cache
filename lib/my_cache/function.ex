defmodule MyCache.Function do
  @type t :: %__MODULE__{
          fun: (() -> {:ok, any()} | {:error, any()}),
          key: any,
          ttl: non_neg_integer(),
          refresh_interval: non_neg_integer(),
          value: any(),
          last_started_at: Time.t()
        }
  @enforce_keys [:fun, :key, :ttl, :refresh_interval]
  defstruct [:fun, :key, :ttl, :refresh_interval, :value, :last_started_at]

  def create_struct(fun, key, ttl, refresh_interval, value \\ nil, last_started_at \\ nil) do
    %__MODULE__{
      fun: fun,
      key: key,
      ttl: ttl,
      refresh_interval: refresh_interval,
      value: value,
      last_started_at: last_started_at
    }
  end
end
