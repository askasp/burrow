defmodule BurrowWeb.BridgeController do
  @moduledoc """
  What Burrow Bridge (`bridge/`) talks to, without a session: pairing
  (`Burrow.Computers.start_pairing/1`, then polling for the token), the
  link a paired computer keeps open (`Burrow.Computers.Link`, which takes
  only the computer's token), and the downloads, with an install script
  for Macs and Linux.
  """

  use BurrowWeb, :controller

  alias Burrow.{Bridge, Computers}

  def pair(conn, params) do
    case Computers.start_pairing(params) do
      {:ok, pairing} ->
        json(conn, %{
          device_code: pairing.device_code,
          user_code: pairing.user_code,
          url: url(~p"/computers/approve?#{[code: pairing.user_code]}"),
          interval: 2,
          expires_in: pairing.expires_in
        })

      {:error, :busy} ->
        conn
        |> put_status(503)
        |> json(%{error: "too many computers are pairing; try again soon"})
    end
  end

  def token(conn, params) do
    case Computers.claim_token(params["device_code"]) do
      {:ok, token, computer} ->
        json(conn, %{token: token, computer: computer.id, name: computer.name})

      :pending ->
        send_resp(conn, 202, "")

      {:error, :expired} ->
        conn |> put_status(410) |> json(%{error: "the code expired or was refused"})
    end
  end

  def socket(conn, _params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %Computers.Computer{} = computer <- Computers.by_token(token) do
      conn
      |> WebSockAdapter.upgrade(Computers.Link, computer,
        timeout: 90_000,
        max_frame_size: 64_000_000
      )
      |> halt()
    else
      _ -> conn |> put_status(401) |> json(%{error: "unknown computer"})
    end
  end

  def download(conn, %{"target" => target}) do
    case Bridge.binary(target) do
      {:ok, path} ->
        conn
        |> put_resp_header("cache-control", "no-cache")
        |> send_download({:file, path}, filename: Bridge.filename(target))

      {:error, :unknown_target} ->
        send_resp(conn, 404, "No Burrow Bridge for #{target}")

      {:error, _} ->
        send_resp(conn, 500, "Burrow Bridge couldn't be built here; see Burrow's log")
    end
  end

  @doc "`curl -fsSL <burrow>/bridge/install.sh | sh` installs the bridge on a Mac or Linux."
  def install(conn, _params) do
    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, install_script(Bridge.server()))
  end

  defp install_script(server) do
    """
    #!/bin/sh
    # Installs Burrow Bridge from #{server}, so Peon can work on files on
    # this computer, in folders you share. Then run: burrow-bridge
    set -e

    case "$(uname -s)" in
      Darwin) os=darwin ;;
      Linux) os=linux ;;
      *) echo "On Windows, download burrow-bridge.exe from #{server}/computers" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
      x86_64 | amd64) arch=amd64 ;;
      arm64 | aarch64) arch=arm64 ;;
      *) echo "No Burrow Bridge for $(uname -m) yet" >&2; exit 1 ;;
    esac

    dir="${BURROW_BRIDGE_DIR:-$HOME/.local/bin}"
    mkdir -p "$dir"
    curl -fsSL "#{server}/bridge/download/$os-$arch" -o "$dir/burrow-bridge.tmp"
    chmod +x "$dir/burrow-bridge.tmp"
    mv "$dir/burrow-bridge.tmp" "$dir/burrow-bridge"

    echo "Installed $dir/burrow-bridge"
    case ":$PATH:" in
      *":$dir:"*) echo "Start it with: burrow-bridge" ;;
      *) echo "Start it with: $dir/burrow-bridge" ;;
    esac
    """
  end
end
