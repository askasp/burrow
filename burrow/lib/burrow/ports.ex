defmodule Burrow.Ports do
  @moduledoc """
  Ports browsers refuse to open (Chromium's and Firefox's restricted ports,
  e.g. 5060/5061 for SIP): a preview or an app on one of them shows as a
  blank page. Port allocation skips them.
  """

  @blocked ~w(1 7 9 11 13 15 17 19 20 21 22 23 25 37 42 43 53 69 77 79 87 95 101 102 103 104 109 110 111 113 115 117 119 123 135 137 139 143 161 179 389 427 465 512 513 514 515 526 530 531 532 540 548 554 556 563 587 601 636 989 990 993 995 1719 1720 1723 2049 3659 4045 4190 5060 5061 6000 6566 6665 6666 6667 6668 6669 6679 6697 10080)a
           |> Enum.map(&(&1 |> Atom.to_string() |> String.to_integer()))

  def browser_safe?(port), do: port not in @blocked

  @doc """
  Where a browser reaches a Peon or app port: `BURROW_PORT_URL` with
  `{port}` filled in (e.g. `https://burrow-{port}.example.com` behind a
  tunnel), or `http://<peon host>:<port>`.
  """
  def url(port), do: String.replace(url_template(), "{port}", to_string(port))

  def host(port), do: URI.parse(url(port)).host

  @doc """
  Where a browser opens the Peon on `port`: `BURROW_PEON_URL` with `{port}`
  filled in (e.g. `https://example.com/w/{port}`, a path on Burrow's own
  site that its router sends to the Peon), or `url/1`.
  """
  def peon_url(port) do
    case Application.get_env(:burrow, :peon_url) do
      nil ->
        url(port)

      template ->
        template |> String.replace("{port}", to_string(port)) |> String.trim_trailing("/")
    end
  end

  @doc "The path a Peon answers under (`PEON_PATH`), nil when it has its own host."
  def peon_path(port) do
    case URI.parse(peon_url(port)).path do
      path when path in [nil, "", "/"] -> nil
      path -> path
    end
  end

  def url_template,
    do:
      Application.get_env(:burrow, :port_url) ||
        "http://#{Application.fetch_env!(:burrow, :peon_host)}:{port}"
end
