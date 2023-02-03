defmodule MyCache.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyCache,
      {Task.Supervisor, name: MyCache.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: MyCache.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
