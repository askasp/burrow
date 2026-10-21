defmodule Totem.Fixture do
  @moduledoc """
  A real app for Totem's tests: a Mix project of its own with a stateful
  GenServer, config and Totem as a path dependency, in `<tmp_dir>/app`.
  """

  import ExUnit.Assertions

  @counter """
  defmodule Demo.Counter do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
    def bump, do: GenServer.call(__MODULE__, :bump)
    def count, do: GenServer.call(__MODULE__, :count)
    def label, do: "v1"
    def greeting, do: Application.get_env(:demo, :greeting)
    @impl true
    def init(n), do: {:ok, n}
    @impl true
    def handle_call(:bump, _from, n), do: {:reply, n + 1, n + 1}
    def handle_call(:count, _from, n), do: {:reply, n, n}
  end
  """

  @doc """
  Writes the app. Options: `:deps` (more deps, as code), `:children` (more
  children of the app's supervisor, as code), `:files` (more files).
  """
  def app!(tmp_dir, opts \\ []) do
    totem = Path.expand("../..", __DIR__)
    dir = Path.join(tmp_dir, "app")
    deps = Enum.join([~s({:totem, path: #{inspect(totem)}}) | Keyword.get(opts, :deps, [])], ", ")
    children = Enum.join(["Demo.Counter" | Keyword.get(opts, :children, [])], ", ")

    files =
      Map.merge(
        %{
          "mix.exs" => """
          defmodule Demo.MixProject do
            use Mix.Project
            def project,
              do: [app: :demo, version: "0.1.0", start_permanent: true, deps: [#{deps}]]
            def application, do: [mod: {Demo.Application, []}]
          end
          """,
          "config/config.exs" => ~s(import Config\nconfig :demo, greeting: "hello"\n),
          "lib/demo/application.ex" => """
          defmodule Demo.Application do
            use Application
            def start(_, _), do: Supervisor.start_link([#{children}], strategy: :one_for_one)
          end
          """,
          "lib/demo/counter.ex" => @counter
        },
        Map.new(Keyword.get(opts, :files, []))
      )

    for {path, content} <- files do
      File.mkdir_p!(Path.join(dir, Path.dirname(path)))
      File.write!(Path.join(dir, path), content)
    end

    if opts[:deps], do: mix!(dir, ["deps.get"])
    dir
  end

  @doc "Runs `body` in the app's node with `mix run`; returns the JSON it evaluates to."
  def run!(dir, body, env \\ []) do
    script = Path.join(Path.dirname(dir), "script-#{System.unique_integer([:positive])}.exs")
    File.write!(script, "result = (\n#{body}\n)\nIO.puts(\"RESULT \" <> JSON.encode!(result))\n")
    {output, status} = mix(dir, ["run", script], env)
    File.rm!(script)

    case Regex.run(~r/^RESULT (.*)$/m, output) do
      [_, json] when status == 0 -> JSON.decode!(json)
      _ -> flunk("script failed (#{status}):\n#{output}")
    end
  end

  def mix!(dir, args, env \\ []) do
    {output, status} = mix(dir, args, env)
    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end

  defp mix(dir, args, env) do
    System.cmd("mix", args,
      cd: dir,
      env: [{"MIX_ENV", "dev"} | env],
      stderr_to_stdout: true
    )
  end
end
