defmodule PeonTemplate.SiteAccess do
  @moduledoc """
  Who can see the app. Change `mode/0` to switch; nothing else has to change.
  """

  # The modes:
  # peon:if-accounts
  # peon:unless-burrow
  #   * :login - people log in with email and password. The app's pages (the
  #     router's :app scope) need a logged-in user.
  # peon:end
  # peon:end
  # peon:if-burrow
  #   * :burrow - an internal app, seen only in Burrow: people log in to
  #     Burrow and come here as themselves (PeonTemplateWeb.BurrowLoginController).
  #     The app's pages need a logged-in user.
  # peon:end
  #   * :basic_auth - the browser asks for one username and password, the
  #     secrets BASIC_AUTH_USERNAME and BASIC_AUTH_PASSWORD. Until both are
  #     set, nobody gets in.
  #   * :shared_password - one password for everyone, asked at /unlock. The
  #     owner sets it in Peon as the secret SITE_PASSWORD; until then nobody
  #     gets in.
  #   * :public - anyone can see every page.
  def mode, do: :login
  # peon:if-accounts

  @doc """
  Whether anyone can make an account at /users/register. When false, only
  the first account is made there; the first account is the admin, who adds
  everyone else at /users/admin.
  """
  def signups?, do: false

  @doc "Whether people have accounts, so the header offers log in and register."
  def accounts?, do: accounts?(mode())

  # By pattern, not `==`: the compiler knows what `mode/0` returns and warns
  # about comparisons that are always true or always false.
  @doc false
  def accounts?(:login), do: true
  def accounts?(_mode), do: false
  # peon:end
end
