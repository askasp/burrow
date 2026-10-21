defmodule Burrow.GitRepo.PreviewPack do
  @moduledoc """
  A repo's preview pack, `.peon/preview.json`: how Burrow runs the repo's own
  dev stack for a chat, on the host, in the chat's checkout (`Burrow.GitRepo.HostPreview`).

      {
        "ports": ["app", "api"],
        "local_ports": ["db"],
        "frame": "app",
        "env": {"PORT_WEB": "{port.app}", "API_URL": "{url.api}", "PROJECT": "{name}"},
        "start": "docker compose up -d --build",
        "stop": "docker compose down -v",
        "ready": "/",
        "check": "docker compose exec -T api npm test"
      }

    * `ports` - named ports a browser reaches through the tunnel; the pane
      frames `frame` (default the first) and links the others
    * `local_ports` - named free host ports with no public address (databases)
    * `env` - extra environment; `{name}` is unique per chat (a good compose
      project name), `{port.X}` and `{url.X}` are the claimed ports and their
      public URLs
    * `start` - shell command; it may keep running or detach and exit 0
    * `stop` - shell command that tears the preview down (optional)
    * `ready` - path on the framed port; any answer below 500 means it is up
    * `check` - shell command that must pass before a submit pushes (optional)

  Every command also gets `PORT` (the framed port), `PEON_NAME`,
  `PEON_PREVIEW_URL` and `PEON_PORT_<NAME>`/`PEON_URL_<NAME>` per port.
  """

  @path ".peon/preview.json"
  @name ~r/\A[a-z][a-z0-9_]{0,30}\z/

  defstruct ports: [],
            local_ports: [],
            frame: nil,
            env: %{},
            start: nil,
            stop: nil,
            ready: "/",
            check: nil

  def path, do: @path

  @doc "Reads the pack in `dir`: `{:ok, pack}`, `:none` or `{:error, message}`."
  def load(dir) do
    case File.read(Path.join(dir, @path)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = map} -> validate(map)
          {:ok, _} -> {:error, "#{@path} must be a JSON object"}
          {:error, error} -> {:error, "#{@path} is not valid JSON: #{Exception.message(error)}"}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, "could not read #{@path}: #{:file.format_error(reason)}"}
    end
  end

  defp validate(map) do
    with {:ok, ports} <- names(map, "ports", required: true),
         {:ok, local} <- names(map, "local_ports", required: false),
         :ok <- distinct(ports ++ local),
         {:ok, frame} <- frame(map["frame"], ports),
         {:ok, start} <- command(map, "start", required: true),
         {:ok, stop} <- command(map, "stop", required: false),
         {:ok, check} <- command(map, "check", required: false),
         {:ok, ready} <- ready(map["ready"]),
         {:ok, env} <- check_env(map["env"], ports, local) do
      {:ok,
       %__MODULE__{
         ports: ports,
         local_ports: local,
         frame: frame,
         env: env,
         start: start,
         stop: stop,
         ready: ready,
         check: check
       }}
    end
  end

  defp names(map, key, required: required) do
    case map[key] do
      nil when not required ->
        {:ok, []}

      [_ | _] = names ->
        if Enum.all?(names, &(is_binary(&1) and &1 =~ @name)),
          do: {:ok, names},
          else: {:error, "#{key} must be names like \"app\" (lowercase letters, digits, _)"}

      _ ->
        {:error, "#{key} must be a list of port names, like [\"app\"]"}
    end
  end

  defp distinct(names) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, "port \"#{dup}\" is named twice"}
    end
  end

  defp frame(nil, [first | _]), do: {:ok, first}

  defp frame(frame, ports) do
    if frame in ports,
      do: {:ok, frame},
      else: {:error, "frame must be one of ports (#{Enum.join(ports, ", ")})"}
  end

  defp command(map, key, required: required) do
    case map[key] do
      nil when not required -> {:ok, nil}
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> {:error, "#{key} must be a shell command"}
    end
  end

  defp ready(nil), do: {:ok, "/"}
  defp ready("/" <> _ = path), do: {:ok, path}
  defp ready(_), do: {:error, "ready must be a path starting with /"}

  defp check_env(nil, _ports, _local), do: {:ok, %{}}

  defp check_env(%{} = env, ports, local) do
    allowed =
      ["name"] ++ Enum.map(ports ++ local, &"port.#{&1}") ++ Enum.map(ports, &"url.#{&1}")

    Enum.reduce_while(env, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      unknown =
        Regex.scan(~r/\{([^}]*)\}/, to_string(value), capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&(&1 in allowed))

      cond do
        not (key =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/) ->
          {:halt, {:error, "env name #{inspect(key)} is not a valid variable name"}}

        not is_binary(value) ->
          {:halt, {:error, "env #{key} must be a string"}}

        unknown != [] ->
          {:halt,
           {:error, "env #{key} uses {#{hd(unknown)}}; known are {#{Enum.join(allowed, "}, {")}}"}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp check_env(_, _ports, _local), do: {:error, "env must be an object of strings"}

  @doc "How many ports the pack claims from the project's range."
  def port_count(%__MODULE__{ports: ports}), do: length(ports)

  @doc """
  The commands' environment, given the claimed `ports` (name => host port,
  for both kinds), a `url` function from port to public URL and the chat's
  unique `name`.
  """
  def env(%__MODULE__{} = pack, ports, url, name) do
    urls = Map.new(pack.ports, &{&1, url.(Map.fetch!(ports, &1))})

    values =
      Map.merge(
        %{"name" => name},
        Map.new(ports, fn {k, port} -> {"port.#{k}", to_string(port)} end)
      )
      |> Map.merge(Map.new(urls, fn {k, u} -> {"url.#{k}", u} end))

    standard =
      %{
        "PORT" => to_string(ports[pack.frame]),
        "PEON_NAME" => name,
        "PEON_PREVIEW_URL" => urls[pack.frame]
      }
      |> Map.merge(
        Map.new(ports, fn {k, p} -> {"PEON_PORT_#{String.upcase(k)}", to_string(p)} end)
      )
      |> Map.merge(Map.new(urls, fn {k, u} -> {"PEON_URL_#{String.upcase(k)}", u} end))

    filled =
      Map.new(pack.env, fn {key, value} ->
        {key, Regex.replace(~r/\{([^}]*)\}/, value, fn _, k -> Map.fetch!(values, k) end)}
      end)

    Map.merge(standard, filled)
  end
end
