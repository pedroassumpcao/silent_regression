defmodule Mix.Tasks.SilentRegression.Invite do
  @shortdoc "Creates a single-use private-alpha workspace invitation"

  @moduledoc """
  Creates or reuses a workspace and emits one single-use invitation URL.

      mix silent_regression.invite \
        --workspace-name "Acme AI" \
        --workspace-slug acme-ai \
        --email owner@acme.example \
        --role owner

  A new workspace can only be created together with an owner invitation. Use
  `--role member` only when the workspace slug already exists. Invitations
  expire after seven days by default; `--validity-days` accepts 1 through 30.
  """

  use Mix.Task

  alias SilentRegression.Workspaces

  @switches [
    workspace_name: :string,
    workspace_slug: :string,
    email: :string,
    role: :string,
    validity_days: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Unknown invitation arguments. Run `mix help silent_regression.invite`.")
    end

    attrs =
      opts
      |> Map.new()
      |> require_options!([:workspace_name, :workspace_slug, :email])

    case Workspaces.operator_create_invitation(attrs) do
      {:ok, result} ->
        Mix.shell().info("Workspace invitation created")
        Mix.shell().info("Workspace: #{result.workspace.name} (#{result.workspace.slug})")
        Mix.shell().info("Email: #{result.invitation.email}")
        Mix.shell().info("Role: #{result.invitation.role}")
        Mix.shell().info("Expires: #{DateTime.to_iso8601(result.invitation.expires_at)}")
        Mix.shell().info("Invitation URL: #{invitation_url(result.token)}")
        Mix.shell().info("The bearer token is shown once and is not stored in plaintext.")

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not create invitation: #{format_changeset_errors(changeset)}")

      {:error, reason} ->
        Mix.raise("Could not create invitation: #{format_reason(reason)}")
    end
  end

  defp require_options!(attrs, required) do
    missing = Enum.filter(required, &(Map.get(attrs, &1) in [nil, ""]))

    if missing == [] do
      attrs
    else
      names = Enum.map_join(missing, ", ", &"--#{String.replace(Atom.to_string(&1), "_", "-")}")
      Mix.raise("Missing required options: #{names}")
    end
  end

  defp invitation_url(token) do
    SilentRegressionWeb.Endpoint.url()
    |> ensure_trailing_slash()
    |> URI.merge("/invitations/#{token}")
    |> URI.to_string()
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp format_reason(:workspace_not_found), do: "member invitations require an existing workspace"
  defp format_reason(:already_member), do: "the email is already a workspace member"
  defp format_reason(:invalid_role), do: "role must be owner or member"
  defp format_reason(:invalid_validity_days), do: "validity-days must be between 1 and 30"
  defp format_reason(reason), do: inspect(reason)

  defp ensure_trailing_slash(url) do
    if String.ends_with?(url, "/"), do: url, else: url <> "/"
  end
end
