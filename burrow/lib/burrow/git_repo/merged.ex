defmodule Burrow.GitRepo.Merged do
  @moduledoc """
  Closes a repo project's chats once GitHub merged their pull request:
  every two minutes it asks GitHub (`Burrow.GitRepo.PullRequest.refresh/1`)
  and deletes each merged chat (`Burrow.Chat.delete/2`) whose agent isn't
  working and whose checkout holds nothing the pushed branch lacks: a chat
  with edits since stays, for its next submit (a new PR).
  """

  use GenServer

  require Logger

  alias Burrow.{Chat, Chats, GitRepo}
  alias Burrow.GitRepo.PullRequest

  @interval :timer.minutes(2)

  @doc """
  Starts it if it doesn't run: a project whose cell started before it
  existed has none.
  """
  def ensure(project) do
    if Registry.lookup(Burrow.ProjectRegistry, {project.id, __MODULE__}) == [],
      do: Burrow.Cell.ensure(project.id, {__MODULE__, project})
  end

  def start_link(project),
    do: GenServer.start_link(__MODULE__, project, name: Burrow.Cell.via(project.id, __MODULE__))

  @impl true
  def init(project) do
    send(self(), :close)
    {:ok, project}
  end

  @impl true
  # A crash here would restart the project's tree with it.
  def handle_info(:close, project) do
    Process.send_after(self(), :close, @interval)
    close(project)
    {:noreply, project}
  rescue
    e ->
      Logger.error("closing merged chats: " <> Exception.format(:error, e, __STACKTRACE__))
      {:noreply, project}
  end

  @doc "Deletes the chats whose PR was merged, as above; returns their ids."
  def close(project) do
    PullRequest.refresh(project)
    busy = Chat.busy_ids(project.id)

    for %{pr_state: "merged"} = chat <- Chats.list(project.id),
        not MapSet.member?(busy, chat.id),
        pushed?(project, chat.id) do
      Chat.delete(project, chat)
      chat.id
    end
  end

  # No edits and no commits beyond what its last submit pushed.
  defp pushed?(project, id) do
    dir = Chat.workspace_dir(project, id)
    git = &GitRepo.git(project, &1, cd: dir)

    not GitRepo.checked_out?(dir) or
      (git.(["status", "--porcelain"]) == {:ok, ""} and
         git.(["rev-list", "--count", "origin/peon/#{id}..HEAD"]) == {:ok, "0\n"})
  end
end
