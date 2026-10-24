defmodule Burrow.OpenCode.Server do
  @moduledoc """
  A short-lived `opencode serve` for one user, used only to manage the user's
  AI logins (opencode's integration and credential API). Runs on the host
  with an isolated, empty config and the user's opencode data directory.
  Stops after `@idle_timeout` without requests.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry Burrow.OpenCodeRegistry
  @idle_timeout :timer.minutes(10)
  @boot_timeout :timer.seconds(30)

  @doc "Sends an API request to the user's server, starting it if needed."
  def request(user_id, method, path, body \\ nil) do
    pid =
      case DynamicSupervisor.start_child(Burrow.OpenCodeSupervisor, {__MODULE__, user_id}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    with {:ok, req} <- GenServer.call(pid, :req, @boot_timeout + 5_000) do
      opts = [method: method, url: path] ++ if(body, do: [json: body], else: [])

      case Req.request(req, opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, exception} -> {:error, exception}
      end
    end
  end

  def child_spec(user_id),
    do: %{
      id: {__MODULE__, user_id},
      start: {__MODULE__, :start_link, [user_id]},
      restart: :temporary
    }

  def start_link(user_id),
    do: GenServer.start_link(__MODULE__, user_id, name: {:via, Registry, {@registry, user_id}})

  @impl true
  def init(user_id) do
    Process.flag(:trap_exit, true)
    base = Path.dirname(Burrow.OpenCode.data_dir(user_id))
    config_dir = Path.join(base, "opencode-login-config")
    work_dir = Path.join(base, "opencode-login-work")
    File.mkdir_p!(Path.join(config_dir, "opencode"))
    File.mkdir_p!(work_dir)
    File.mkdir_p!(Burrow.OpenCode.data_dir(user_id))

    File.write!(
      Path.join([config_dir, "opencode", "opencode.json"]),
      Jason.encode!(%{
        "$schema" => "https://opencode.ai/config.json",
        "autoupdate" => false,
        "share" => "disabled",
        "provider" => Burrow.OpenCode.custom_providers()
      })
    )

    password = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    port = free_port()

    os_port =
      Port.open({:spawn_executable, Application.fetch_env!(:burrow, :opencode_bin)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["serve", "--hostname", "127.0.0.1", "--port", Integer.to_string(port)],
        cd: work_dir,
        env: [
          {~c"XDG_CONFIG_HOME", to_charlist(config_dir)},
          {~c"XDG_DATA_HOME", to_charlist(Burrow.OpenCode.data_dir(user_id))},
          {~c"OPENCODE_SERVER_PASSWORD", to_charlist(password)}
        ]
      ])

    req =
      Req.new(
        base_url: "http://127.0.0.1:#{port}/api",
        auth: {:basic, "opencode:" <> password},
        receive_timeout: 30_000,
        retry: false
      )

    send(self(), :wait_ready)

    {:ok,
     %{
       user_id: user_id,
       port: os_port,
       req: req,
       ready?: false,
       waiting: [],
       booted_at: System.monotonic_time(:millisecond),
       idle_ref: nil
     }}
  end

  @impl true
  def handle_call(:req, _from, %{ready?: true} = state),
    do: {:reply, {:ok, state.req}, touch(state)}

  def handle_call(:req, from, state), do: {:noreply, %{state | waiting: [from | state.waiting]}}

  @impl true
  def handle_info(:wait_ready, state) do
    cond do
      match?({:ok, %{status: 200}}, Req.get(state.req, url: "/info")) ->
        Enum.each(state.waiting, &GenServer.reply(&1, {:ok, state.req}))
        {:noreply, touch(%{state | ready?: true, waiting: []})}

      System.monotonic_time(:millisecond) - state.booted_at > @boot_timeout ->
        Enum.each(state.waiting, &GenServer.reply(&1, {:error, :boot_timeout}))
        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :wait_ready, 300)
        {:noreply, state}
    end
  end

  def handle_info(:idle, state), do: {:stop, :normal, state}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("opencode login server for user #{state.user_id} exited with #{code}")
    Enum.each(state.waiting, &GenServer.reply(&1, {:error, {:exited, code}}))
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
      nil -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_timeout)}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
