# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.DataLive.Index do
  @moduledoc """
  The admin's data pages: the app's tables (`:schemas`), and a table's rows
  (`:rows`) to search, filter and page through. See `PeonTemplate.Backoffice`.
  """
  use PeonTemplateWeb, :live_view

  import PeonTemplateWeb.DataLive.Components

  alias PeonTemplate.Backoffice

  @impl true
  def render(%{live_action: :schemas} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        Data
        <:subtitle>Every table of the app. Fields marked redact never show here.</:subtitle>
      </.header>

      <.table
        id="schemas"
        rows={@schemas}
        row_id={&"schema-#{&1.source}"}
        row_click={&JS.navigate(rows_path(&1.name))}
      >
        <:col :let={s} label="Schema">{s.name}</:col>
        <:col :let={s} label="Table"><span class="font-mono text-sm">{s.source}</span></:col>
        <:col :let={s} label="Rows">{s.count}</:col>
      </.table>
      <p :if={@schemas == []} class="opacity-70">The app has no tables yet.</p>
    </Layouts.app>
    """
  end

  def render(%{live_action: :rows} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        {@entry.name}
        <:subtitle>
          <.link navigate={~p"/users/admin/data"} class="link">Data</.link>
          · {@page.total} {if @page.total == 1, do: "row", else: "rows"} in
          <span class="font-mono">{@entry.source}</span>
        </:subtitle>
        <:actions>
          <.button
            :if={@creatable?}
            navigate={~p"/users/admin/data/#{@entry.name}/new"}
            variant="primary"
            data-kb-key="a"
            data-kb-label="New row"
          >
            New row
          </.button>
        </:actions>
      </.header>

      <form id="search" phx-change="search" phx-submit="search">
        <input
          type="search"
          name="q"
          value={@q}
          placeholder="Search the text, or an id"
          class="input w-full"
          autocomplete="off"
          phx-debounce="300"
          data-kb="search"
        />
      </form>

      <div :if={@filter != %{}} class="flex flex-wrap gap-2">
        <.link
          :for={{field, value} <- @filter}
          id={"filter-#{field}"}
          patch={rows_path(@entry.name, @q, Map.delete(@filter, field))}
          class="badge badge-outline gap-1"
          title="Remove this filter"
        >
          {field} = {value} <.icon name="hero-x-mark" class="size-3" />
        </.link>
      </div>

      <div class="overflow-x-auto">
        <.table
          id="rows"
          rows={@page.rows}
          row_id={&"row-#{row_key(@entry, &1)}"}
          row_click={@linkable? && (&JS.navigate(row_path(@entry.name, row_key(@entry, &1))))}
        >
          <:col :let={row} :for={{field, _type} <- @fields} label={Atom.to_string(field)}>
            <.value value={Map.get(row, field)} short />
          </:col>
        </.table>
      </div>
      <p :if={@page.rows == []} class="opacity-70">No rows.</p>

      <nav :if={@page.pages > 1} class="flex items-center gap-4">
        <.link
          :if={@page.page > 1}
          id="newer"
          patch={rows_path(@entry.name, @q, @filter, @page.page - 1)}
          class="link"
        >
          ← Newer
        </.link>
        <span class="text-sm opacity-70">Page {@page.page} of {@page.pages}</span>
        <.link
          :if={@page.page < @page.pages}
          id="older"
          patch={rows_path(@entry.name, @q, @filter, @page.page + 1)}
          class="link"
        >
          Older →
        </.link>
      </nav>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _url, %{assigns: %{live_action: :schemas}} = socket) do
    schemas = for s <- Backoffice.schemas(), do: Map.put(s, :count, Backoffice.count(s.schema))
    {:noreply, assign(socket, page_title: "Data", schemas: schemas)}
  end

  def handle_params(%{"schema" => name} = params, _url, socket) do
    case Backoffice.schema(name) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "The app has no #{name}.")
         |> push_navigate(to: ~p"/users/admin/data")}

      entry ->
        q = params["q"] || ""
        filter = if is_map(params["filter"]), do: params["filter"], else: %{}
        linkable? = Backoffice.linkable?(entry.schema)

        {:noreply,
         assign(socket,
           page_title: entry.name,
           entry: entry,
           q: q,
           filter: filter,
           fields: Backoffice.fields(entry.schema),
           linkable?: linkable?,
           creatable?: linkable? and Backoffice.editable(entry.schema) != [],
           page: Backoffice.list(entry.schema, q: q, filter: filter, page: params["page"])
         )}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    %{entry: entry, filter: filter} = socket.assigns
    {:noreply, push_patch(socket, to: rows_path(entry.name, String.trim(q), filter))}
  end

  # A row without one primary key has no page; its place in the list will do.
  defp row_key(entry, row) do
    if Backoffice.linkable?(entry.schema),
      do: Backoffice.id(entry.schema, row),
      else: :erlang.phash2(row)
  end
end
