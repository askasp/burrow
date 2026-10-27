defmodule Burrow.Bridge do
  @moduledoc """
  Burrow Bridge's downloads. The Go source (`bridge/` in the repo,
  `:bridge_dir`) is built for a target (`Burrow.Computers.targets/0`) on
  its first download, a few seconds, with this Burrow's address inside, so
  the bridge pairs with no questions. Builds go in
  `<data_dir>/bridge/<version>/`; the version is a hash of the source and
  the address, so a change to either builds anew.
  """

  require Logger

  @doc "The built binary for `target` (e.g. \"darwin-arm64\"), building it if needed."
  def binary(target) do
    with {:ok, goos, goarch} <- parse(target) do
      version = version()
      path = Path.join([data_dir(), version, "burrow-bridge-#{target}#{ext(goos)}"])

      if File.exists?(path),
        do: {:ok, path},
        else: :global.trans({__MODULE__, target}, fn -> build(path, goos, goarch, version) end)
    end
  end

  @doc "The file name a download of `target` gets."
  def filename(target) do
    case parse(target) do
      {:ok, goos, _} -> "burrow-bridge#{ext(goos)}"
      _ -> "burrow-bridge"
    end
  end

  defp parse(target) do
    with true <- Enum.any?(Burrow.Computers.targets(), &(elem(&1, 0) == target)),
         [goos, goarch] <- String.split(target, "-") do
      {:ok, goos, goarch}
    else
      _ -> {:error, :unknown_target}
    end
  end

  defp ext("windows"), do: ".exe"
  defp ext(_goos), do: ""

  defp build(path, goos, goarch, version) do
    # Another download may have built it while this one waited.
    if File.exists?(path) do
      {:ok, path}
    else
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"
      ldflags = "-s -w -X main.server=#{server()} -X main.version=#{version}"

      case System.cmd(go(), ["build", "-trimpath", "-ldflags", ldflags, "-o", tmp, "."],
             cd: source(),
             env: [{"GOOS", goos}, {"GOARCH", goarch}, {"CGO_ENABLED", "0"}],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          File.rename!(tmp, path)
          prune(version)
          {:ok, path}

        {output, status} ->
          File.rm(tmp)

          Logger.error(
            "building Burrow Bridge for #{goos}-#{goarch} failed (#{status}): #{output}"
          )

          {:error, :build_failed}
      end
    end
  end

  # Builds of older versions go once a new one is there.
  defp prune(version) do
    for dir <- File.ls!(data_dir()), dir != version, do: File.rm_rf(Path.join(data_dir(), dir))
  end

  defp go,
    do: System.find_executable("go") || raise("go not found: Burrow Bridge needs Go to build")

  @doc "The version downloads get now: a hash of the bridge's source and this Burrow's address."
  def version do
    files =
      source()
      |> Path.join("{go.mod,go.sum,*.go}")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "_test.go"))
      |> Enum.sort()

    :crypto.hash_init(:sha256)
    |> :crypto.hash_update(server())
    |> then(&Enum.reduce(files, &1, fn f, acc -> :crypto.hash_update(acc, File.read!(f)) end))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end

  @doc "Where the bridge finds this Burrow."
  def server, do: BurrowWeb.Endpoint.url()

  defp source, do: Application.fetch_env!(:burrow, :bridge_dir)

  defp data_dir, do: Path.join(Application.fetch_env!(:burrow, :data_dir), "bridge")
end
