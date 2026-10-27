defmodule Burrow.Template do
  @moduledoc """
  Instantiates the template app for a new project: copies its files, renaming
  `PeonTemplate` / `peon_template` to the project's module and OTP app name in
  paths and contents.

  The project picks its login (`auth`):

    * `"accounts"` - the template as it is: phx.gen.auth's email and password
      accounts, `SiteAccess` mode `:login`. The first account is the admin,
      who adds the others; with `signups: true` anyone can sign up too
      (`SiteAccess.signups?/0`).
    * `"basic"` - no accounts; the browser asks for one username and password
      (`SiteAccess` mode `:basic_auth`, the secrets `BASIC_AUTH_USERNAME` and
      `BASIC_AUTH_PASSWORD`).
    * `"open"` - no accounts and no login (`SiteAccess` mode `:public`).
    * `"burrow"` - an internal app: accounts, but people log in through
      Burrow as themselves (`SiteAccess` mode `:burrow`,
      `BurrowWeb.AppController`); no password pages.

  Each app gets only its login's code, following markers in the template's
  comments (`#`, `<%!--` or `<!--`, whole line):

    * `peon:accounts-only` - the whole file only in apps with accounts
      ("accounts" and "burrow"); `peon:burrow-only` only in "burrow" apps;
      `peon:not-burrow` in every app but those.
    * `peon:if-accounts` ... `peon:end` - lines only apps with accounts get,
      `peon:if-burrow` ... `peon:end` lines only "burrow" apps get. Blocks nest.
    * `peon:unless-accounts`, `peon:unless-burrow` ... `peon:end` - the
      other apps' lines. `unless-accounts` is only for text and comments: the
      template itself runs with accounts, and with both the lines of
      `if-burrow` and `unless-burrow`.

  The marker lines themselves never reach the app.
  """

  @module "PeonTemplate"
  @otp_app "peon_template"
  @auths ~w(accounts basic open burrow)
  @site_access "lib/peon_template/site_access.ex"
  @default_mode "def mode, do: :login"
  @default_signups "def signups?, do: false"

  @marker ~r/^\s*(?:#|<%!--|<!--)\s*peon:((?:accounts|burrow)-only|not-burrow|(?:if|unless)-(?:accounts|burrow)|end)\b/
  @file_markers ~w(accounts-only burrow-only not-burrow)

  @doc "The logins a new project can start with."
  def auths, do: @auths

  @doc """
  Returns `{tree, blobs}` for `Totem.Tree`, ready to import. Option:
  `signups: true` lets anyone sign up to an app with accounts.
  """
  def instantiate(template_dir, otp_app, auth \\ "accounts", opts \\ []) when auth in @auths do
    module = Macro.camelize(otp_app)
    {tree, blobs} = Totem.Tree.from_dir(template_dir, Burrow.Workspace.ignore(template_dir))
    signups? = Keyword.get(opts, :signups, false)

    Enum.reduce(tree, {%{}, %{}}, fn {path, hash}, {tree, new_blobs} ->
      case variant(path, Map.fetch!(blobs, hash), auth) do
        :skip ->
          {tree, new_blobs}

        {:ok, content} ->
          content = content |> set_mode(path, auth, signups?) |> rename(module, otp_app)
          new_hash = Totem.Blob.hash(content)

          {Map.put(tree, rename(path, module, otp_app), new_hash),
           Map.put(new_blobs, new_hash, content)}
      end
    end)
  end

  @doc "Turns a project slug into a valid OTP app name."
  def otp_app(slug) do
    name = slug |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    if name =~ ~r/^[a-z]/, do: name, else: "app_" <> name
  end

  @doc false
  # A file as an app with login `auth` gets it: `{:ok, content}` or `:skip`.
  def variant(path, content, auth) do
    if String.contains?(content, "peon:") and String.valid?(content),
      do: apply_markers(path, content, auth),
      else: {:ok, content}
  end

  # The open blocks are a stack of keep?s; a line stays when all say so.
  defp apply_markers(path, content, auth) do
    {lines, blocks, skip?} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], [], false}, fn line, {lines, blocks, skip?} ->
        case Regex.run(@marker, line, capture: :all_but_first) do
          nil ->
            {if(Enum.all?(blocks), do: [line | lines], else: lines), blocks, skip?}

          ["end"] when blocks != [] ->
            {lines, tl(blocks), skip?}

          [file] when file in @file_markers and blocks == [] ->
            {lines, [], skip? or not keep?(file, auth)}

          [block] when block not in ["end" | @file_markers] ->
            {lines, [keep?(block, auth) | blocks], skip?}

          [marker] ->
            raise ArgumentError, "#{path}: unexpected peon:#{marker}"
        end
      end)

    cond do
      blocks != [] -> raise ArgumentError, "#{path}: a peon:if block has no peon:end"
      skip? -> :skip
      true -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  defp keep?("accounts-only", auth), do: auth in ~w(accounts burrow)
  defp keep?("burrow-only", auth), do: auth == "burrow"
  defp keep?("not-burrow", auth), do: auth != "burrow"
  defp keep?("if-" <> what, auth), do: keep?(what <> "-only", auth)
  defp keep?("unless-" <> what, auth), do: not keep?(what <> "-only", auth)

  # The login the app starts with is the one line in SiteAccess; with
  # accounts, so is whether anyone can sign up.
  defp set_mode(content, @site_access, "accounts", false), do: content

  defp set_mode(content, @site_access, "accounts", true),
    do: replace_line(content, @default_signups, "def signups?, do: true")

  defp set_mode(content, @site_access, auth, _signups?) do
    mode = %{"basic" => ":basic_auth", "open" => ":public", "burrow" => ":burrow"}[auth]
    replace_line(content, @default_mode, "def mode, do: " <> mode)
  end

  defp set_mode(content, _path, _auth, _signups?), do: content

  defp replace_line(content, line, new) do
    if String.contains?(content, line),
      do: String.replace(content, line, new),
      else: raise(ArgumentError, "#{@site_access} has no `#{line}` line")
  end

  defp rename(text, module, otp_app) do
    text |> String.replace(@module, module) |> String.replace(@otp_app, otp_app)
  end
end
