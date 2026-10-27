defmodule BurrowWeb.BridgeControllerTest do
  use BurrowWeb.ConnCase, async: false

  import Burrow.AccountsFixtures

  alias Burrow.Computers

  test "pairing: a code to approve, then the token once it's approved", %{conn: conn} do
    body =
      conn
      |> post(~p"/bridge/pair", %{name: "laptop", os: "darwin", arch: "arm64", version: "v1"})
      |> json_response(200)

    assert %{"device_code" => device_code, "user_code" => code, "url" => url, "interval" => 2} =
             body

    assert url =~ "/computers/approve?code=#{code}"

    assert build_conn()
           |> post(~p"/bridge/pair/token", %{device_code: device_code})
           |> response(202)

    {:ok, _} = Computers.approve(user_fixture(), code)

    assert %{"token" => "bb_" <> _, "name" => "laptop"} =
             build_conn()
             |> post(~p"/bridge/pair/token", %{device_code: device_code})
             |> json_response(200)

    assert %{"error" => _} =
             build_conn()
             |> post(~p"/bridge/pair/token", %{device_code: device_code})
             |> json_response(410)
  end

  test "the link takes only a paired computer's token", %{conn: conn} do
    assert conn |> get(~p"/bridge/socket") |> json_response(401)

    assert build_conn()
           |> put_req_header("authorization", "Bearer bb_nope")
           |> get(~p"/bridge/socket")
           |> json_response(401)
  end

  test "the install script fetches this Burrow's build for the computer", %{conn: conn} do
    script = conn |> get(~p"/bridge/install.sh") |> response(200)
    assert script =~ "#{Burrow.Bridge.server()}/bridge/download/$os-$arch"
    assert build_conn() |> get(~p"/bridge/download/plan9-mips") |> response(404)
  end
end
