# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.UserLive.Admin do
  @moduledoc """
  The admin's list of accounts: add one with an email and a first password,
  or remove one. Whether people can also sign up themselves is
  `PeonTemplate.SiteAccess.signups?/0`.
  """
  use PeonTemplateWeb, :live_view

  alias PeonTemplate.Accounts
  alias PeonTemplate.Accounts.User
  alias PeonTemplate.SiteAccess
  alias PeonTemplateWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Users
        <:subtitle>
          <%= if @signups? do %>
            Anyone can sign up. You can also add people here.
          <% else %>
            Sign-ups are closed: only the people you add here can log in.
          <% end %>
        </:subtitle>
      </.header>

      <.form for={@form} id="add_user_form" phx-submit="add" phx-change="validate">
        <.input field={@form[:email]} type="email" label="Email" spellcheck="false" required />
        <.input
          field={@form[:password]}
          type="password"
          label="First password"
          autocomplete="new-password"
          required
        />
        <p class="text-sm opacity-70 mb-2">
          Pass the password on yourself; they can change it in their settings.
        </p>
        <.button
          variant="primary"
          phx-disable-with="Adding..."
          data-kb-key="a"
          data-kb-label="Add user"
        >
          Add user
        </.button>
      </.form>

      <.table id="users" rows={@users} row_id={&"user-#{&1.id}"}>
        <:col :let={user} label="Email">{user.email}</:col>
        <:col :let={user} label="Role">{if user.admin, do: "Admin", else: "User"}</:col>
        <:col :let={user} label="Added">{Calendar.strftime(user.inserted_at, "%Y-%m-%d")}</:col>
        <:action :let={user}>
          <span :if={user.id == @current_scope.user.id} class="opacity-70">You</span>
          <.link
            :if={user.id != @current_scope.user.id}
            phx-click="remove"
            phx-value-id={user.id}
            data-confirm={"Remove #{user.email}? They are logged out and can't log in again."}
          >
            Remove
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(signups?: SiteAccess.signups?())
     |> assign_users()
     |> assign_form(Accounts.change_user_registration(%User{}))}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("add", %{"user" => user_params}, socket) do
    case Accounts.add_user(socket.assigns.current_scope, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added #{user.email}.")
         |> assign_users()
         |> assign_form(Accounts.change_user_registration(%User{}))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:ok, {user, tokens}} = Accounts.delete_user(socket.assigns.current_scope, user)
    UserAuth.disconnect_sessions(tokens)

    {:noreply, socket |> put_flash(:info, "Removed #{user.email}.") |> assign_users()}
  end

  defp assign_users(socket),
    do: assign(socket, users: Accounts.list_users(socket.assigns.current_scope))

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, form: to_form(changeset, as: "user"))
end
