# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.DataLive.Form do
  @moduledoc """
  Adds or edits a row on the admin's data pages, through the schema's
  `changeset/2` when it has one (`PeonTemplate.Backoffice.change/3`).
  """
  use PeonTemplateWeb, :live_view

  import PeonTemplateWeb.DataLive.Components

  alias PeonTemplate.Backoffice

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {if @live_action == :new, do: "New #{@entry.name}", else: "Edit #{@entry.name} #{@id}"}
        <:subtitle>
          <.link navigate={~p"/users/admin/data"} class="link">Data</.link>
          · <.link navigate={rows_path(@entry.name)} class="link">{@entry.name}</.link>
        </:subtitle>
      </.header>

      <.form for={@form} id="row_form" phx-change="validate" phx-submit="save">
        <p :for={msg <- @other_errors} class="text-error text-sm mb-2">{msg}</p>
        <.row_input
          :for={{name, type} <- @editable}
          form={@form}
          schema={@entry.schema}
          name={name}
          type={type}
        />
        <div class="flex items-center gap-4">
          <.button variant="primary" phx-disable-with="Saving...">Save</.button>
          <.link navigate={@back} class="link">Cancel</.link>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :schema, :atom, required: true
  attr :name, :atom, required: true
  attr :type, :any, required: true

  defp row_input(assigns) do
    assigns =
      assign(assigns, input: Backoffice.input(assigns.type), label: to_string(assigns.name))

    ~H"""
    <.input
      :if={@input == "select"}
      field={@form[@name]}
      type="select"
      label={@label}
      prompt="—"
      options={Backoffice.options(@schema, @name)}
    />
    <.input
      :if={@input == "number"}
      field={@form[@name]}
      type="number"
      label={@label}
      step={if @type in [:float, :decimal], do: "any", else: "1"}
    />
    <.input
      :if={@input == "datetime-local"}
      field={@form[@name]}
      type="datetime-local"
      label={"#{@label} (UTC)"}
      step="1"
      value={datetime_value(@form[@name].value)}
    />
    <.input
      :if={@input not in ["select", "number", "datetime-local"]}
      field={@form[@name]}
      type={@input}
      label={@label}
    />
    """
  end

  # With seconds, so saving without touching it doesn't drop them.
  defp datetime_value(%DateTime{} = at), do: at |> DateTime.to_naive() |> datetime_value()

  defp datetime_value(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

  defp datetime_value(value), do: value

  @impl true
  def mount(%{"schema" => name} = params, _session, socket) do
    with %{} = entry <- Backoffice.schema(name),
         true <- Backoffice.linkable?(entry.schema),
         [_ | _] = editable <- Backoffice.editable(entry.schema),
         %{} = row <- load(entry.schema, socket.assigns.live_action, params) do
      back =
        if socket.assigns.live_action == :new,
          do: rows_path(entry.name),
          else: row_path(entry.name, params["id"])

      {:ok,
       socket
       |> assign(
         page_title: entry.name,
         entry: entry,
         id: params["id"],
         row: row,
         editable: editable,
         back: back
       )
       |> assign_form(Backoffice.change(entry.schema, row))}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That can't be edited here.")
         |> push_navigate(to: ~p"/users/admin/data")}
    end
  end

  defp load(schema, :new, _params), do: struct(schema)
  defp load(schema, :edit, %{"id" => id}), do: Backoffice.get(schema, id)

  @impl true
  def handle_event("validate", %{"row" => params}, socket) do
    %{entry: entry, row: row} = socket.assigns
    changeset = Backoffice.change(entry.schema, row, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"row" => params}, socket) do
    %{entry: entry, row: row} = socket.assigns

    case Backoffice.save(entry.schema, row, params) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved.")
         |> push_navigate(to: row_path(entry.name, Backoffice.id(entry.schema, saved)))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    shown = Enum.map(socket.assigns.editable, &elem(&1, 0))

    # Errors the form has no field for: the database's, or a changeset/2's
    # on fields it doesn't show.
    other =
      if changeset.action,
        do: for({f, error} <- changeset.errors, f not in shown, do: other_error(f, error)),
        else: []

    assign(socket, form: to_form(changeset, as: "row"), other_errors: other)
  end

  defp other_error(:base, error), do: translate_error(error)
  defp other_error(field, error), do: "#{field} #{translate_error(error)}"
end
