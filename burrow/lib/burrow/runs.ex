defmodule Burrow.Runs do
  @moduledoc """
  What happened to main's changes: a main check (`kind` "check") or a deploy
  to an environment (`kind` "deploy"), with its status and why.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Burrow.Repo

  schema "runs" do
    field :project_id, :integer
    field :kind, :string
    field :env, :string
    field :change_id, :integer
    # check: running, passed, failed; deploy: deploying, healthy, failed
    field :status, :string
    field :mode, :string
    field :detail, :string
    timestamps(type: :utc_datetime)
  end

  def start(project_id, kind, env, change_id, fields \\ []) do
    struct!(
      __MODULE__,
      [project_id: project_id, kind: kind, env: env, change_id: change_id, status: "running"] ++
        fields
    )
    |> Repo.insert!()
  end

  def finish(%__MODULE__{} = run, fields),
    do: run |> Ecto.Changeset.change(fields) |> Repo.update!()

  def list(project_id, kind, env \\ nil, limit \\ 10) do
    query =
      from r in __MODULE__,
        where: r.project_id == ^project_id and r.kind == ^kind,
        order_by: [desc: r.id],
        limit: ^limit

    Repo.all(if env, do: where(query, [r], r.env == ^env), else: query)
  end

  def last(project_id, kind, env \\ nil), do: List.first(list(project_id, kind, env, 1))

  def failed?(project_id, kind, env, change_id),
    do:
      Repo.exists?(
        from r in __MODULE__,
          where:
            r.project_id == ^project_id and r.kind == ^kind and r.env == ^env and
              r.change_id == ^change_id and r.status == "failed"
      )
end
