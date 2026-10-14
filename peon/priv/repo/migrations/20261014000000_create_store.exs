defmodule Peon.Repo.Migrations.CreateStore do
  use Ecto.Migration

  def change do
    create table(:project) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :settings, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create table(:blobs, primary_key: false) do
      add :hash, :string, primary_key: true
      add :content, :binary, null: false
      add :size, :integer, null: false
    end

    create table(:changesets) do
      add :parent_id, references(:changesets)
      add :rebased_from_id, references(:changesets)
      add :author_kind, :string, null: false
      add :author_id, :string, null: false
      add :intent, :text, null: false
      add :files, :map, null: false
      add :status, :string, null: false
      add :flags, :map, null: false, default: %{}
      add :checks, :map, null: false, default: %{}
      add :conversation_id, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:changesets, [:parent_id])
    create index(:changesets, [:status])

    create table(:changeset_paths, primary_key: false) do
      add :path, :string, null: false
      add :changeset_id, references(:changesets), null: false
    end

    create index(:changeset_paths, [:path, :changeset_id])

    create table(:trees, primary_key: false) do
      add :changeset_id, references(:changesets), primary_key: true
      add :entries, :map, null: false
    end

    create table(:refs, primary_key: false) do
      add :name, :string, primary_key: true
      add :changeset_id, references(:changesets), null: false
      add :version, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:events) do
      add :actor, :string, null: false
      add :action, :string, null: false
      add :details, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:tokens) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :token_hash, :string, null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:tokens, [:token_hash])
  end
end
