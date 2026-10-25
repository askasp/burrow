# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.DataLive.Components do
  @moduledoc "What the admin's data pages share: their paths and how a value shows."
  use PeonTemplateWeb, :html

  alias PeonTemplate.Backoffice

  @doc "A table's rows, searched for `q`, filtered by `filter`, at `page`."
  def rows_path(name, q \\ "", filter \\ %{}, page \\ 1) do
    query = Enum.reject([q: q, filter: filter, page: page], fn {_k, v} -> v in ["", %{}, 1] end)

    if query == [],
      do: ~p"/users/admin/data/#{name}",
      else: ~p"/users/admin/data/#{name}?#{query}"
  end

  @doc "A row's page."
  def row_path(name, id), do: ~p"/users/admin/data/#{name}/#{id}"

  attr :value, :any, required: true
  attr :short, :boolean, default: false, doc: "cut long text, for tables"

  @doc "A field's value as text; an empty one as a dash."
  def value(assigns) do
    text = Backoffice.text(assigns.value)
    short = text && assigns.short && String.length(text) > 60

    assigns =
      assign(assigns,
        text: text,
        shown: if(short, do: String.slice(text, 0, 60) <> "…", else: text)
      )

    ~H"""
    <span :if={@text == nil} class="opacity-50">—</span>
    <span :if={@text != nil} title={@shown != @text && @text}>{@shown}</span>
    """
  end
end
