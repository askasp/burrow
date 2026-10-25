defmodule Burrow.FakeEnv do
  @moduledoc "Stands in for a project's `Burrow.Env` in tests: its `info` is what it was given."

  use GenServer

  def start_link({project_id, name, info}),
    do:
      GenServer.start_link(__MODULE__, info,
        name: Burrow.Cell.via(project_id, {Burrow.Env, name})
      )

  @impl true
  def init(info), do: {:ok, info}

  @impl true
  def handle_call(:info, _from, info), do: {:reply, info, info}
end
