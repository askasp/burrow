defmodule Peon.Store.Blob do
  use Ecto.Schema

  @primary_key {:hash, :string, autogenerate: false}
  schema "blobs" do
    field :content, :binary
    field :size, :integer
  end
end

defmodule Peon.Store.Changeset do
  use Ecto.Schema

  @statuses ~w(proposed checking passed failed superseded)

  @derive {Jason.Encoder,
           only:
             ~w(id parent_id rebased_from_id author_kind author_id intent files status flags checks conversation_id inserted_at)a}
  schema "changesets" do
    field :parent_id, :id
    field :rebased_from_id, :id
    field :author_kind, :string
    field :author_id, :string
    field :intent, :string
    # [%{"path" => path, "hash" => hash | nil}], nil hash = deleted
    field :files, {:array, :map}
    field :status, :string

    # %{"restart_required" => bool, "destructive_migrations" => [path], "approved_destructive" => bool}
    field :flags, :map, default: %{}
    field :checks, :map, default: %{}
    field :conversation_id, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def statuses, do: @statuses

  @doc "The changeset's files as `PeonCore.Tree` changes."
  def changes(%__MODULE__{files: files}) do
    Enum.map(files, fn %{"path" => path, "hash" => hash} -> {path, hash || :deleted} end)
  end
end

defmodule Peon.Store.ChangesetPath do
  use Ecto.Schema

  @primary_key false
  schema "changeset_paths" do
    field :path, :string
    field :changeset_id, :id
  end
end

defmodule Peon.Store.TreeCache do
  use Ecto.Schema

  @primary_key {:changeset_id, :id, autogenerate: false}
  schema "trees" do
    field :entries, :map
  end
end

defmodule Peon.Store.Ref do
  use Ecto.Schema

  @derive {Jason.Encoder, only: [:name, :changeset_id, :version, :updated_at]}
  @primary_key {:name, :string, autogenerate: false}
  schema "refs" do
    field :changeset_id, :id
    field :version, :integer
    timestamps(type: :utc_datetime)
  end
end

defmodule Peon.Store.Event do
  use Ecto.Schema

  @derive {Jason.Encoder, only: [:id, :actor, :action, :details, :inserted_at]}
  schema "events" do
    field :actor, :string
    field :action, :string
    field :details, :map, default: %{}
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
