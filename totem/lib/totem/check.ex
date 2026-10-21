defmodule Totem.Check do
  @moduledoc """
  Builds and tests a tree that isn't running, without touching the app: in a
  scratch directory, with the app's deps linked in and its test build
  copied as a start, in a separate OS process.
  """

  @script "mix compile --warnings-as-errors && mix test"

  @doc "Checks `files` (path => content) next to the app in `root`: `{:ok, output}` or `{:error, output}`."
  @spec run(Path.t(), String.t(), %{String.t() => binary()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(root, id, files) do
    dir = Path.join([root, ".totem", "check", id])
    File.rm_rf!(dir)

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    deps = Path.join(root, "deps")
    if File.dir?(deps), do: File.ln_s!(deps, Path.join(dir, "deps"))
    build = Path.join([root, "_build", "test"])
    if File.dir?(build), do: File.cp_r!(build, Path.join([dir, "_build", "test"]))

    case System.cmd("sh", ["-c", @script],
           cd: dir,
           env: [{"MIX_ENV", "test"}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  after
    File.rm_rf(Path.join([root, ".totem", "check", id]))
  end
end
