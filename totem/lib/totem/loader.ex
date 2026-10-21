defmodule Totem.Loader do
  @moduledoc """
  Loads the app's code into the node it runs in, the way the app was started:
  under Mix (`mix phx.server`, `mix run`), which compiles in this node.

    * hot - recompiles: changed modules are replaced, processes keep running
      with their state and pick up the new code on their next call
    * warm - stops the app (not the node), reloads its config, recompiles
      and starts it again: for config, application.ex and the endpoint
  """

  require Logger

  @doc "True when the node runs under Mix, so it can compile."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil

  @doc """
  Recompiles changed modules, as IEx's `recompile` does, and returns the
  compiler's output with its errors either way. `force: true` recompiles
  every module: after a failed compile, whose modules Mix already unloaded
  and whose .beam files it deleted.
  """
  @spec hot(keyword()) :: {:ok | :error, String.t()}
  def hot(opts \\ []) do
    config = Mix.Project.config()
    compilers = Enum.map(config[:compilers] || Mix.compilers(), &"compile.#{&1}")
    Enum.each(["compile", "compile.all", "compile.protocols" | compilers], &Mix.Task.reenable/1)
    args = if opts[:force], do: ["--return-errors", "--force"], else: ["--return-errors"]

    {{status, diagnostics}, output} = capture(fn -> Mix.Task.run("compile", args) end)
    errors = for %{severity: :error} = d <- diagnostics, do: format(d)
    output = Enum.join([output | errors], "\n")

    {if(status == :error, do: :error, else: :ok), output}
  end

  defp format(%{file: file, position: position, message: message}) do
    line =
      case position do
        {line, _column} -> line
        line -> line
      end

    "#{Path.relative_to_cwd(to_string(file))}:#{line}: #{message}"
  end

  @doc "Stops `otp_app`, reloads its config from `root`, recompiles and starts it again."
  @spec warm(atom(), Path.t(), keyword()) :: {:ok | :error, String.t()}
  def warm(otp_app, root, opts \\ []) do
    stop(otp_app)
    reload_config(root)

    case hot(opts) do
      {:ok, output} -> start(otp_app, output)
      {:error, output} -> {:error, output}
    end
  end

  @doc "Starts `otp_app` if it isn't running, e.g. after a warm load failed."
  @spec start(atom(), String.t()) :: {:ok | :error, String.t()}
  def start(otp_app, output \\ "") do
    case Application.ensure_all_started(otp_app) do
      {:ok, _} -> {:ok, output}
      {:error, reason} -> {:error, output <> "\n" <> inspect(reason)}
    end
  end

  defp stop(otp_app) do
    case Application.stop(otp_app) do
      :ok -> :ok
      {:error, {:not_started, _}} -> :ok
    end
  end

  # config.exs (with its imports) and runtime.exs, as Mix read them at boot.
  defp reload_config(root) do
    opts = [env: Mix.env(), target: Mix.target()]

    config =
      for file <- ["config/config.exs", "config/runtime.exs"],
          path = Path.join(root, file),
          File.exists?(path),
          reduce: [] do
        acc -> Config.Reader.merge(acc, Config.Reader.read!(path, opts))
      end

    Application.put_all_env(config, persistent: true)
  end

  defp capture(fun) do
    {:ok, io} = StringIO.open("")
    leader = Process.group_leader()
    Process.group_leader(self(), io)

    try do
      result = fun.()
      {_, output} = StringIO.contents(io)
      {result, output}
    after
      Process.group_leader(self(), leader)
      StringIO.close(io)
    end
  end
end
