defmodule Mix.Tasks.SilentRegression.InviteTest do
  use SilentRegression.DataCase, async: false

  import ExUnit.CaptureIO
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Invitation, Workspace}

  setup do
    Mix.Task.reenable("silent_regression.invite")
    :ok
  end

  test "creates an owner invitation and prints the bearer URL once" do
    slug = unique_workspace_slug()
    email = unique_workspace_email()

    output =
      capture_io(fn ->
        Mix.Tasks.SilentRegression.Invite.run([
          "--workspace-name",
          "Operator Workspace",
          "--workspace-slug",
          slug,
          "--email",
          email,
          "--role",
          "owner",
          "--validity-days",
          "5"
        ])
      end)

    workspace = Repo.get_by!(Workspace, slug: slug)
    invitation = Repo.get_by!(Invitation, workspace_id: workspace.id)

    assert output =~ "Workspace invitation created"
    assert output =~ "Invitation URL: http://localhost:4000/invitations/"
    assert output =~ "The bearer token is shown once"
    assert invitation.email == email
    assert invitation.role == :owner
    assert DateTime.diff(invitation.expires_at, DateTime.utc_now(:second), :day) in 4..5
  end

  test "fails closed when required options are missing" do
    assert_raise Mix.Error,
                 ~r/Missing required options: --workspace-name, --workspace-slug/,
                 fn ->
                   capture_io(fn ->
                     Mix.Tasks.SilentRegression.Invite.run(["--email", unique_workspace_email()])
                   end)
                 end
  end
end
