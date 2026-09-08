defmodule Mix.Tasks.BurpeeTrainer.LinkOidc do
  @shortdoc "Link an OIDC subject identifier to the existing user account"

  @moduledoc """
  Links a Pocket ID subject identifier (`sub`) to the local user account,
  so OIDC login resolves to the existing account and its workout history.

  Run this BEFORE switching the login page over to OIDC, and verify the
  result with:

      sqlite3 burpee_trainer.db "SELECT id, username, oidc_sub FROM users;"

  ## Usage

      mix burpee_trainer.link_oidc <sub>
      mix burpee_trainer.link_oidc <sub> --username <pocket-id-username>
      mix burpee_trainer.link_oidc <sub> --force

  `--username` is advisory: it warns when the Pocket ID username differs
  from the local one. `--force` allows relinking a user that already has
  a sub.
  """

  use Mix.Task

  alias BurpeeTrainer.Accounts
  alias BurpeeTrainer.Repo

  @scoped_tables ~w(
    workout_plans goals workout_sessions style_performances
    user_stats planning_drafts execution_plans pose_capture_runs
  )

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [username: :string, force: :boolean])

    sub = List.first(positional)

    if is_nil(sub) or sub == "" do
      Mix.raise("Usage: mix burpee_trainer.link_oidc <sub> [--username NAME] [--force]")
    end

    Mix.Task.run("app.start")

    user = sole_user!()
    guard_existing_link!(user, opts[:force])
    report(user, sub, opts[:username])
    confirm!()

    case Accounts.link_oidc_sub(user, sub) do
      {:ok, linked} ->
        Mix.shell().info("")

        Mix.shell().info(
          "Linked user #{linked.id} (#{linked.username}) to sub #{linked.oidc_sub}"
        )

      {:error, changeset} ->
        Mix.raise("Failed to link: #{inspect(changeset.errors)}")
    end
  end

  defp sole_user! do
    case Repo.all(Accounts.User) do
      [user] ->
        user

      [] ->
        Mix.raise("No users exist. Create one before linking.")

      users ->
        Mix.raise(
          "Expected exactly one user, found #{length(users)}. " <>
            "Refusing to guess which to link."
        )
    end
  end

  defp guard_existing_link!(user, force) do
    if user.oidc_sub && !force do
      Mix.raise(
        "User #{user.id} (#{user.username}) is already linked to sub " <>
          "#{user.oidc_sub}. Re-run with --force to relink."
      )
    end
  end

  defp report(user, sub, provider_username) do
    Mix.shell().info("About to link OIDC identity to this account:")
    Mix.shell().info("")
    Mix.shell().info("  id:        #{user.id}")
    Mix.shell().info("  username:  #{user.username}")
    Mix.shell().info("  oidc_sub:  #{user.oidc_sub || "(none)"} -> #{sub}")
    Mix.shell().info("")
    Mix.shell().info("Data owned by this account:")

    for table <- @scoped_tables do
      count = count_for(table, user.id)
      Mix.shell().info("  #{String.pad_trailing(table, 20)} #{count}")
    end

    warn_username_mismatch(user, provider_username)
  end

  defp count_for(table, user_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM #{table} WHERE user_id = ?", [user_id])

    count
  rescue
    _ -> "(table missing)"
  end

  defp warn_username_mismatch(_user, nil), do: :ok

  defp warn_username_mismatch(user, provider_username) do
    if user.username != provider_username do
      Mix.shell().info("")

      Mix.shell().error(
        "WARNING: Pocket ID username #{inspect(provider_username)} differs " <>
          "from local username #{inspect(user.username)}. This is allowed — " <>
          "identity is established by sub, not by name — but confirm this is " <>
          "the account you mean."
      )
    end
  end

  # `Mix.shell().yes?/1` treats a bare Enter (or empty piped stdin) as yes,
  # which is the wrong default for a one-time write to the account that owns
  # all workout history. Require the operator to type "yes" explicitly.
  defp confirm! do
    Mix.shell().info("")

    answer = Mix.shell().prompt("Link this account? Type 'yes' to confirm:")

    unless is_binary(answer) and String.trim(answer) == "yes" do
      Mix.raise("Aborted.")
    end
  end
end
