defmodule BurrowWeb.Peek do
  @moduledoc """
  Another place's chats in the drawer, without leaving the page: "Switch
  to" and the projects page pick a place (a project, or `"chats"` for
  Chats) and the drawer lists its chats, each a link into it
  (`BurrowWeb.WorkspaceLive.Components.peek_list/1`). Picking the page's
  own place goes back to its own list.
  """

  use BurrowWeb, :verified_routes

  alias Burrow.{Activity, Chat, GeneralChat, GeneralChats, Projects, Ship}
  alias BurrowWeb.ChatsLive
  alias BurrowWeb.WorkspaceLive.Components

  @doc """
  Shows `place` in the socket's drawer (`:peek`), or the page's own list
  when it is `here` or not a place the user can open.
  """
  def pick(socket, place, here) do
    peek =
      if to_string(place) != to_string(here),
        do: load(socket.assigns.current_scope, place, socket.assigns.rail)

    Phoenix.Component.assign(socket, peek: peek)
  end

  @doc "The place again, after something changed in it; the page's own list stays."
  def reload(%{assigns: %{peek: %{id: id}}} = socket, here), do: pick(socket, id, here)
  def reload(socket, _here), do: socket

  @doc """
  `place` as the drawer lists it: `%{id, name, sub, tile, new_url, days}`,
  `days` as `[{day, rows}]`, the last worked on first. Nil when the user
  can't open it.
  """
  def load(scope, "chats", _rail) do
    user_id = scope.user.id
    busy = GeneralChat.busy_ids(user_id)

    days =
      for {day, chats} <- ChatsLive.history(GeneralChats.list(user_id), nil) do
        {day,
         for c <- chats do
           busy? = MapSet.member?(busy, c.id)

           %{
             id: c.id,
             title: ChatsLive.title(c),
             url: ~p"/chats/#{c.id}",
             status: if(busy?, do: {"Searching", "working"}),
             meta: ChatsLive.sub(c, busy?),
             done?: false
           }
         end}
      end

    %{
      id: "chats",
      name: "Chats",
      sub: "Ask, search, think · no project",
      tile: nil,
      new_url: ~p"/chats",
      days: days
    }
  end

  def load(scope, place, rail) do
    with {id, ""} <- Integer.parse(to_string(place)),
         true <- Projects.visible?(scope, id) do
      project = Projects.get!(scope, id)
      live_only? = not Ship.staging?(project)
      tabs = Activity.chats(project, scope.user.id, Chat.busy_ids(project.id))
      tile = Enum.find(rail, &(&1.id == id)) || Activity.of(project) |> tile()

      %{
        id: id,
        name: project.name,
        sub: tile.label,
        tile: tile,
        new_url: ~p"/projects/#{id}/c/new",
        days:
          for {day, tabs, _done} <- Components.by_day(tabs, live_only?) do
            {day, Enum.map(tabs, &row(&1, project, live_only?))}
          end
      }
    else
      _ -> nil
    end
  end

  defp row(tab, project, live_only?) do
    %{
      id: tab.chat.id,
      title: Components.chat_title(tab, project, false),
      url: ~p"/projects/#{project.id}/c/#{tab.chat.id}",
      status: Components.row_status(tab, live_only?),
      meta: Components.row_meta(tab),
      done?: Activity.done?(tab, live_only?)
    }
  end

  defp tile(tile), do: %{state: tile["state"], label: tile["label"], pct: tile["pct"]}
end
