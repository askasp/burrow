defmodule BurrowWeb.ComputersLiveTest do
  use BurrowWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Burrow.Computers

  setup :register_and_log_in_user

  test "approving a computer's code pairs it with the user", %{conn: conn, user: user} do
    {:ok, pairing} =
      Computers.start_pairing(%{"name" => "laptop", "os" => "darwin", "arch" => "arm64"})

    {:ok, lv, html} = live(conn, ~p"/computers/approve?code=#{pairing.user_code}")
    assert html =~ "Approve this computer?"
    assert has_element?(lv, "#approve-code", pairing.user_code)
    assert html =~ "Mac"

    lv |> element("#approve-btn") |> render_click()
    assert_patch(lv, ~p"/computers")
    assert render(lv) =~ "laptop is paired"

    assert {:ok, _token, computer} = Computers.claim_token(pairing.device_code)
    assert computer.user_id == user.id
    assert has_element?(lv, "#computer-#{computer.id}", "laptop")
    assert has_element?(lv, "#computer-#{computer.id}", "Offline")
  end

  test "a code that isn't waiting says so", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/computers/approve?code=AAAA-BBBB")
    assert has_element?(lv, "#approve-gone")
  end

  test "the page offers the downloads and removes a computer", %{conn: conn, user: user} do
    {:ok, pairing} =
      Computers.start_pairing(%{"name" => "desk", "os" => "windows", "arch" => "amd64"})

    {:ok, _} = Computers.approve(user, pairing.user_code)
    {:ok, _token, computer} = Computers.claim_token(pairing.device_code)

    {:ok, lv, html} = live(conn, ~p"/computers")
    assert html =~ "/bridge/install.sh | sh"
    assert has_element?(lv, "#download-windows[href='/bridge/download/windows-amd64']")

    lv |> element("#remove-computer-#{computer.id}") |> render_click()
    refute has_element?(lv, "#computer-#{computer.id}")
    assert Computers.list(user.id) == []
  end
end
