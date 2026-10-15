defmodule BurrowWeb.UserLive.Registration do
  use BurrowWeb, :live_view

  alias Burrow.Accounts
  alias Burrow.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">Create account</h1>

      <.form
        for={@form}
        id="registration_form"
        phx-submit="save"
        phx-change="validate"
        phx-trigger-action={@trigger_submit}
        action={~p"/users/log-in?_action=registered"}
        method="post"
        class="flex flex-col"
      >
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          placeholder="you@example.com"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="new-password"
          hint="At least 12 characters."
          reveal
          required
        />

        <.button
          variant="primary"
          phx-disable-with="Creating account…"
          class="btn btn-primary btn-lg w-full mt-2"
        >
          Create account
        </.button>
      </.form>

      <div class="pt-5 border-t border-[var(--border)] text-sm leading-5 text-[var(--text-2)]">
        Have an account? <.link navigate={~p"/users/log-in"}>Log in</.link>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: BurrowWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{})

    {:ok, socket |> assign(trigger_submit: false) |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user_with_password(user_params) do
      {:ok, user} ->
        changeset = Accounts.change_user_registration(user, user_params)
        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
