# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplate.Backoffice do
  @moduledoc """
  The admin's data pages (/users/admin/data): every Ecto schema of the app
  with a table, found at run time, to browse, search, add to, edit and
  delete from. New schemas show up by themselves.

  Fields marked `redact: true` never show and can't be set, so mark secrets
  and tokens that way. A row is saved through its schema's `changeset/2` when
  it has one; otherwise the fields a form can hold are cast as they are.
  """

  import Ecto.Query, warn: false
  alias PeonTemplate.Repo

  @otp_app :peon_template
  @per_page 50

  @doc """
  The app's schemas with a table, by name: `[%{name, schema, source}]`. The
  name is the module without the app's prefix, such as `"Accounts.User"`.
  """
  def schemas do
    prefix = inspect(PeonTemplate) <> "."

    for module <- modules(), schema?(module) do
      %{
        name: String.replace_prefix(inspect(module), prefix, ""),
        schema: module,
        source: module.__schema__(:source)
      }
    end
    |> Enum.sort_by(& &1.name)
  end

  # The compiled modules, from the app's ebin: it has what was compiled since
  # the app started too, which the app's spec doesn't.
  defp modules do
    for path <- Path.wildcard(Path.join(Application.app_dir(@otp_app, "ebin"), "*.beam")),
        do: path |> Path.basename(".beam") |> String.to_atom()
  end

  defp schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and
      is_binary(module.__schema__(:source))
  end

  @doc "The schema called `name` (see `schemas/0`), or nil."
  def schema(name), do: Enum.find(schemas(), &(&1.name == name))

  @doc "The fields shown, as `{field, type}`: all but the redacted ones."
  def fields(schema) do
    redacted = schema.__schema__(:redact_fields)
    for f <- schema.__schema__(:fields), f not in redacted, do: {f, schema.__schema__(:type, f)}
  end

  @doc """
  The fields a form sets: not the primary key, what Ecto sets itself (the
  timestamps) or values a form can't hold (maps, lists, binaries, embeds).
  """
  def editable(schema) do
    auto = for {fields, _how} <- schema.__schema__(:autogenerate), f <- fields, do: f
    skip = schema.__schema__(:primary_key) ++ auto

    for {f, type} <- fields(schema), f not in skip, input(type) != nil, do: {f, type}
  end

  @doc "The form input for a field's type, or nil when a form can't set it."
  def input(:string), do: "text"
  def input(:binary_id), do: "text"
  def input(type) when type in [:id, :integer, :float, :decimal], do: "number"
  def input(:boolean), do: "checkbox"
  def input(:date), do: "date"
  def input(type) when type in [:time, :time_usec], do: "time"

  def input(type)
      when type in [:naive_datetime, :naive_datetime_usec, :utc_datetime, :utc_datetime_usec],
      do: "datetime-local"

  def input({:parameterized, {Ecto.Enum, _params}}), do: "select"
  def input(_type), do: nil

  @doc "The options of an `Ecto.Enum` field."
  def options(schema, field), do: Ecto.Enum.values(schema, field)

  @doc "Whether rows have one primary key, so each has a page and can be edited."
  def linkable?(schema), do: match?([_], schema.__schema__(:primary_key))

  @doc "A row's primary key value."
  def id(schema, row) do
    [pk] = schema.__schema__(:primary_key)
    Map.fetch!(row, pk)
  end

  @doc "How many rows the table has."
  def count(schema), do: Repo.aggregate(schema, :count)

  @doc """
  A page of rows, the newest first: `%{rows, total, page, pages}`. Options:

    * `:q` - text to search for in the text fields (any case), or a row's id.
    * `:filter` - `%{"field" => value}` over the fields shown.
    * `:page` - from 1.
  """
  def list(schema, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @per_page)

    query =
      schema
      |> search(schema, opts[:q])
      |> filter(schema, opts[:filter] || %{})

    total = Repo.aggregate(query, :count)
    pages = max(ceil(total / per_page), 1)
    page = opts[:page] |> to_page() |> min(pages)
    order = for pk <- schema.__schema__(:primary_key), do: {:desc, pk}

    rows =
      query
      |> order_by(^order)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{rows: rows, total: total, page: page, pages: pages}
  end

  defp to_page(page) when is_integer(page) and page > 0, do: page

  defp to_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp to_page(_page), do: 1

  defp search(query, _schema, q) when q in [nil, ""], do: query

  defp search(query, schema, q) do
    q = String.trim(q)
    text = for {f, :string} <- fields(schema), do: dynamic([r], like(field(r, ^f), ^"%#{q}%"))

    by_id =
      with true <- linkable?(schema),
           [pk] = schema.__schema__(:primary_key),
           {:ok, id} <- Ecto.Type.cast(schema.__schema__(:type, pk), q) do
        [dynamic([r], field(r, ^pk) == ^id)]
      else
        _ -> []
      end

    case text ++ by_id do
      [] ->
        where(query, false)

      [first | rest] ->
        where(query, ^Enum.reduce(rest, first, fn d, acc -> dynamic(^acc or ^d) end))
    end
  end

  defp filter(query, schema, filter) do
    Enum.reduce(fields(schema), query, fn {f, type}, query ->
      case Map.fetch(filter, Atom.to_string(f)) do
        {:ok, value} when value in [nil, ""] ->
          where(query, [r], is_nil(field(r, ^f)))

        {:ok, value} ->
          case Ecto.Type.cast(type, value) do
            {:ok, value} -> where(query, [r], field(r, ^f) == ^value)
            _ -> where(query, false)
          end

        :error ->
          query
      end
    end)
  end

  @doc "The row with this id (as text from a URL), or nil."
  def get(schema, id) do
    with true <- linkable?(schema),
         [pk] = schema.__schema__(:primary_key),
         {:ok, id} <- Ecto.Type.cast(schema.__schema__(:type, pk), id) do
      Repo.get(schema, id)
    else
      _ -> nil
    end
  end

  @doc """
  What a row links to, among the app's schemas: the row a `belongs_to`
  points at, `%{name, kind: :parent, schema, id}`, and the rows that point
  at it (`has_many`, `has_one`), `%{name, kind: :children, schema, filter,
  count}`. Through and many-to-many associations are left out.
  """
  def links(schema, row) do
    names = Map.new(schemas(), &{&1.schema, &1.name})

    for assoc <- schema.__schema__(:associations),
        link = link(schema.__schema__(:association, assoc), row, names),
        link != nil,
        do: link
  end

  defp link(%Ecto.Association.BelongsTo{} = a, row, names) do
    id = Map.get(row, a.owner_key)

    if id != nil and Map.has_key?(names, a.related) and linkable?(a.related),
      do: %{name: a.field, kind: :parent, schema: names[a.related], id: id}
  end

  defp link(%Ecto.Association.Has{} = a, row, names) do
    value = Map.get(row, a.owner_key)

    if value != nil and Map.has_key?(names, a.related) do
      key = a.related_key
      count = Repo.aggregate(from(r in a.related, where: field(r, ^key) == ^value), :count)

      %{
        name: a.field,
        kind: :children,
        schema: names[a.related],
        filter: %{Atom.to_string(key) => to_string(value)},
        count: count
      }
    end
  end

  defp link(_assoc, _row, _names), do: nil

  @doc """
  A changeset for a new row (`struct(schema)`) or a loaded one: the schema's
  own `changeset/2` when it has one, otherwise the `editable/1` fields cast.
  """
  def change(schema, row, attrs \\ %{}) do
    if function_exported?(schema, :changeset, 2) do
      schema.changeset(row, attrs)
    else
      fields = Enum.map(editable(schema), &elem(&1, 0))

      Enum.reduce(fields, Ecto.Changeset.cast(row, attrs, fields), fn f, changeset ->
        # Turns a unique index's error (named the Ecto way) into the field's.
        Ecto.Changeset.unique_constraint(changeset, f)
      end)
    end
  end

  @doc """
  Inserts a new row or updates a loaded one. What the database refuses
  (a missing value, a key to no row) comes back as an error on `:base`.
  """
  def save(schema, row, attrs) do
    changeset = change(schema, row, attrs)

    try do
      Repo.insert_or_update(changeset)
    rescue
      e in [Ecto.ConstraintError, Exqlite.Error] ->
        action = if row.__meta__.state == :loaded, do: :update, else: :insert

        {:error,
         changeset
         |> Map.put(:action, action)
         |> Ecto.Changeset.add_error(:base, "The database refused it: #{refusal(e)}")}
    end
  end

  @doc """
  Deletes a row. Rows that point at it go with it or stop it, as their
  foreign keys say; what the database refuses comes back as
  `{:error, message}`.
  """
  def delete(row) do
    case Repo.delete(row, stale_error_field: :base) do
      {:ok, row} ->
        {:ok, row}

      {:error, changeset} ->
        {:error, Enum.map_join(changeset.errors, "; ", &elem(elem(&1, 1), 0))}
    end
  rescue
    e in [Ecto.ConstraintError, Exqlite.Error] ->
      {:error, "The database refused it: #{refusal(e)}"}
  end

  defp refusal(%Ecto.ConstraintError{type: type, constraint: name}), do: "#{type} #{name}"
  defp refusal(%Exqlite.Error{} = e), do: Exception.message(e)

  @doc "A value as text for the pages; nil stays nil."
  def text(nil), do: nil
  def text(true), do: "yes"
  def text(false), do: "no"
  def text(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
  def text(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")
  def text(%Date{} = date), do: Date.to_iso8601(date)
  def text(%Time{} = time), do: Time.to_iso8601(time)
  def text(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  def text(value) when is_atom(value) or is_number(value), do: to_string(value)

  def text(value) when is_binary(value) do
    if String.printable?(value), do: value, else: "(#{byte_size(value)} bytes)"
  end

  def text(value), do: inspect(value, limit: 20, printable_limit: 200)
end
