defmodule BurrowWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BurrowWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The app's frame: the header (mark, main nav, account) and a centered main
  column. `active` marks the current nav link.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, values: [nil, :projects, :teams, :ai, :logins, :settings]
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <header class="border-b border-[var(--border)]">
        <div class="max-w-[1200px] mx-auto px-6 py-3.5 flex items-center gap-6 flex-wrap">
          <.link
            navigate={if @current_scope, do: ~p"/projects", else: ~p"/"}
            class="flex items-center gap-[9px] no-underline text-[var(--text)]"
            aria-label="Peon home"
          >
            <.mark size={24} />
            <span class="text-lg font-bold tracking-[-0.03em]">peon</span>
          </.link>
          <%= if @current_scope do %>
            <nav aria-label="Main" class="mr-auto flex items-center gap-5">
              <.link
                navigate={~p"/projects"}
                class="navlink"
                data-kb="tab"
                data-kb-go="p"
                aria-current={@active == :projects && "page"}
              >
                Projects
              </.link>
              <.link
                navigate={~p"/teams"}
                class="navlink"
                data-kb="tab"
                data-kb-go="t"
                aria-current={@active == :teams && "page"}
              >
                Teams
              </.link>
              <.link
                navigate={~p"/ai"}
                class="navlink"
                data-kb="tab"
                data-kb-go="a"
                aria-current={@active == :ai && "page"}
              >
                AI login
              </.link>
              <.link
                :if={@current_scope.user.admin}
                navigate={~p"/logins"}
                class="navlink"
                data-kb="tab"
                data-kb-go="l"
                aria-current={@active == :logins && "page"}
              >
                Logins
              </.link>
            </nav>
            <.theme_switch theme={@current_scope.user.theme} />
            <.link
              navigate={~p"/users/settings"}
              data-kb-go=","
              data-kb-label="Settings"
              class="text-[13px] text-[var(--text-3)] no-underline hover:text-[var(--text)]"
              aria-current={@active == :settings && "page"}
            >
              {@current_scope.user.email}
            </.link>
            <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
              Log out
            </.link>
          <% else %>
            <span class="mr-auto"></span>
            <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
            <.link
              :if={Burrow.Accounts.sign_ups?()}
              navigate={~p"/users/register"}
              class="btn btn-secondary btn-sm"
            >
              Create account
            </.link>
          <% end %>
        </div>
      </header>

      <main class="w-full max-w-[1200px] mx-auto px-6 pt-10 pb-20 flex flex-col gap-8">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc "The signed-in user's theme for `<html data-theme>`; \"system\" follows the device."
  def theme(assigns) do
    case assigns[:current_scope] do
      %{user: %{theme: theme}} -> theme
      _ -> "system"
    end
  end

  attr :theme, :string, required: true

  @doc "System, light or dark, for Burrow and every Peon."
  def theme_switch(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/users/theme"} method="post" class="theme-switch" aria-label="Theme">
      <button
        :for={
          {value, icon, label} <- [
            {"system", "hero-computer-desktop", "System"},
            {"light", "hero-sun", "Light"},
            {"dark", "hero-moon", "Dark"}
          ]
        }
        name="theme"
        value={value}
        aria-pressed={to_string(@theme == value)}
        aria-label={"#{label} theme"}
        title={"#{label} theme"}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </.form>
    """
  end

  @doc """
  The frame for logging in and signing up: the mark on top, one narrow
  column in the middle of the page.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col">
      <header class="w-full max-w-[1200px] mx-auto px-6 py-5 flex items-center">
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2.5 no-underline text-[var(--text)]"
          aria-label="Peon home"
        >
          <.mark size={28} />
          <span class="text-xl font-bold tracking-[-0.03em]">peon</span>
        </.link>
      </header>
      <main class="flex-1 flex items-center justify-center px-4 pt-6 pb-24">
        <div class="w-full max-w-[360px] flex flex-col gap-7">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  An asset's path. In dev the files keep their names, and the tunnel tells
  browsers to cache them for hours, so the path carries the file's build time.
  """
  def asset(path) do
    file = Application.app_dir(:burrow, Path.join("priv/static", path))

    with true <- BurrowWeb.Endpoint.config(:code_reloader) == true,
         {:ok, %{mtime: mtime}} <- File.stat(file, time: :posix) do
      "#{path}?v=#{mtime}"
    else
      _ -> path
    end
  end

  @doc "The Peon mark: a peon's face on the accent green."
  attr :size, :integer, default: 24
  attr :label, :string, default: nil

  def mark(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 48 48"
      class="block flex-none"
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={!@label && "true"}
    >
      <rect width="48" height="48" rx="11" fill="#8FBF5A"></rect>
      <circle cx="18" cy="21" r="3.2" fill="#1C2412"></circle>
      <circle cx="30" cy="21" r="3.2" fill="#1C2412"></circle>
      <path d="M15.2 37.5 L17.4 29 L19.8 37.5 Z" fill="#F7F4EA"></path>
      <path d="M28.2 37.5 L30.6 29 L32.8 37.5 Z" fill="#F7F4EA"></path>
    </svg>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
