defmodule Burrow.TicketsTest do
  use ExUnit.Case, async: true

  alias Burrow.Tickets

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    %{dir: Path.join(tmp, "tickets")}
  end

  # The agent's own tk, as it runs in its container: TICKETS_DIR set.
  defp tk(dir, args) do
    tk = Application.app_dir(:burrow, "priv/tk/tk")
    env = [{"TICKETS_DIR", dir}]
    {out, 0} = System.cmd("bash", [tk | args], cd: Path.dirname(dir), env: env)
    String.trim(out)
  end

  test "tickets the agent makes with tk are in the queue, in progress first", %{dir: dir} do
    first = tk(dir, ["create", "Add the schedule page"])
    second = tk(dir, ["create", "Send reminders", "-p", "1"])
    tk(dir, ["start", first])
    done = tk(dir, ["create", "Pick colors"])
    tk(dir, ["close", done])

    assert [
             %{id: ^first, status: "in_progress", title: "Add the schedule page"},
             %{id: ^second, status: "open", priority: 1},
             %{id: ^done, status: "closed"}
           ] = Tickets.list(dir)

    assert [_, _] = dir |> Tickets.list() |> Tickets.unfinished()
  end

  test "a ticket the user adds is one tk works with", %{dir: dir} do
    {:ok, id} = Tickets.create(dir, "  Make the   logo bigger ", "On every page")

    assert tk(dir, ["ready"]) =~ id
    assert tk(dir, ["show", id]) =~ "On every page"
    tk(dir, ["start", id])
    assert [%{id: ^id, status: "in_progress", title: "Make the logo bigger"}] = Tickets.list(dir)
  end

  test "tickets the user adds in a row stay in that order", %{dir: dir} do
    titles = ["Logo", "Header", "Footer", "Colors"]
    for title <- titles, do: {:ok, _} = Tickets.create(dir, title)

    assert Enum.map(Tickets.list(dir), & &1.title) == titles
  end

  test "tk ready lists the queue in the order the user sees, the next one first", %{dir: dir} do
    agents = for title <- ["Logo", "Header"], do: tk(dir, ["create", title])
    {:ok, users} = Tickets.create(dir, "Footer")
    urgent = tk(dir, ["create", "Fix login", "-p", "1"])
    tk(dir, ["start", List.last(agents)])

    ready = for line <- String.split(tk(dir, ["ready"]), "\n"), do: hd(String.split(line))

    assert ready == Enum.map(Tickets.list(dir), & &1.id)
    assert ready == [List.last(agents), urgent, hd(agents), users]
  end

  test "only tickets that haven't started can be deleted", %{dir: dir} do
    {:ok, open} = Tickets.create(dir, "Later")
    {:ok, started} = Tickets.create(dir, "Now")
    tk(dir, ["start", started])

    assert :ok = Tickets.delete(dir, open)
    assert {:error, :started} = Tickets.delete(dir, started)
    assert {:error, :not_found} = Tickets.delete(dir, "../../etc/passwd")
    assert [%{id: ^started}] = Tickets.list(dir)
  end

  test "no queue yet is an empty one, for tk too", %{dir: dir} do
    assert Tickets.list(dir) == []
    # The agent runs `tk ready` before it finishes: nothing open is no error.
    File.mkdir_p!(dir)
    assert tk(dir, ["ready"]) == ""
  end
end
