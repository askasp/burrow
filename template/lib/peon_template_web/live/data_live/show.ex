# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.DataLive.Show do
  @moduledoc """
  One row on the admin's data pages: its fields, the rows it links to, and
  editing or deleting it (not the admin's own account).
  """
  use PeonTemplateWeb, :live_view

  import PeonTemplateWeb.DataLive.Components

  alias PeonTemplate.{Accounts, Backoffice}
  alias PeonTemplate.Accounts.User
  alias PeonTemplateWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <.header>
        {@entry.name} {@id}
        <:subtitle>
          <.link navigate={~p"/users/admin/data"} class="link">Data</.link>
          · <.link navigate={rows_path(@entry.name)} class="link">{@entry.name}</.link>
        </:subtitle>
        <:actions>
          <.button
            :if={not @own?}
            id="delete"
            phx-click="delete"
            data-confirm={"Delete #{@entry.name} #{@id}? Rows that point at it may go with it."}
          >
            Delete
          </.button>
          <.button
            :if={@editable?}
            navigate={~p"/users/admin/data/#{@entry.name}/#{@id}/edit"}
            variant="primary"
            data-kb-key="e"
            data-kb-label="Edit"
          >
            Edit
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item :for={{field, _type} <- @fields} title={Atom.to_string(field)}>
          <.value value={Map.get(@row, field)} />
        </:item>
      </.list>

      <section :if={@links != []} id="links" class="space-y-2">
        <h2 class="font-semibold">Linked rows</h2>
        <ul class="space-y-1">
          <li :for={link <- @links} id={"link-#{link.name}"}>
            <.link
              :if={link.kind == :parent}
              navigate={row_path(link.schema, link.id)}
              class="link"
            >
              {link.name}: {link.schema} {link.id}
            </.link>
            <.link
              :if={link.kind == :children}
              navigate={rows_path(link.schema, "", link.filter)}
              class="link"
            >
              {link.name}: {link.count} in {link.schema}
            </.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event("delete", _params, %{assigns: %{own?: true}} = socket),
    do: {:noreply, put_flash(socket, :error, "You can't delete your own account.")}

  def handle_event("delete", _params, socket) do
    %{entry: entry, row: row, id: id} = socket.assigns

    case delete(socket.assigns.current_scope, row) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{entry.name} #{id}.")
         |> push_navigate(to: rows_path(entry.name))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # An account goes as on the Users page: its open pages are logged out too.
  defp delete(scope, %User{} = user) do
    case Accounts.delete_user(scope, user) do
      {:ok, {_user, tokens}} -> UserAuth.disconnect_sessions(tokens)
      {:error, _changeset} -> {:error, "The account could not be deleted."}
    end
  end

  defp delete(_scope, row) do
    with {:ok, _row} <- Backoffice.delete(row), do: :ok
  end

  # The admin's own account: deleting it here would lock them out.
  defp own?(%{user: %{__struct__: schema, id: id}}, %{__struct__: schema, id: id}), do: true
  defp own?(_scope, _row), do: false

  @impl true
  def handle_params(%{"schema" => name, "id" => id}, _url, socket) do
    with %{} = entry <- Backoffice.schema(name),
         %{} = row <- Backoffice.get(entry.schema, id) do
      {:noreply,
       assign(socket,
         page_title: "#{entry.name} #{id}",
         entry: entry,
         id: id,
         row: row,
         fields: Backoffice.fields(entry.schema),
         editable?: Backoffice.editable(entry.schema) != [],
         own?: own?(socket.assigns.current_scope, row),
         links: Backoffice.links(entry.schema, row)
       )}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "There is no #{name} #{id}.")
         |> push_navigate(to: ~p"/users/admin/data")}
    end
  end
end
