defmodule Mix.Tasks.BurpeeTrainer.CreateUser do
  @shortdoc "Interactively create the (single) user"

  @moduledoc """
  Seeds the single user. Prompts for username and password on stdin.

      mix burpee_trainer.create_user

  Refuses to create a second user if one already exists, so you can run
  it on a fresh machine without worrying about clobbering data.
  """

  use Mix.Task

  alias BurpeeTrainer.Accounts

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    if Accounts.any_user?() do
      Mix.shell().error("A user already exists. Refusing to create another.")
      exit({:shutdown, 1})
    end

    username = prompt_username()
    password = prompt_password()

    case Accounts.register_user(%{"username" => username, "password" => password}) do
      {:ok, user} ->
        Mix.shell().info("Created user '#{user.username}' (id=#{user.id}).")

      {:error, changeset} ->
        errors = format_errors(changeset)
        Mix.shell().error("Could not create user:\n#{errors}")
        exit({:shutdown, 1})
    end
  end

  defp prompt_username do
    case Mix.shell().prompt("Username:") |> String.trim() do
      "" ->
        Mix.shell().error("Username cannot be blank.")
        prompt_username()

      username ->
        username
    end
  end

  defp prompt_password do
    password = read_password_hidden("Password: ")
    confirm = read_password_hidden("Confirm password: ")

    cond do
      password != confirm ->
        Mix.shell().error("Passwords do not match, try again.")
        prompt_password()

      String.length(password) < 8 ->
        Mix.shell().error("Password must be at least 8 characters.")
        prompt_password()

      true ->
        password
    end
  end

  defp read_password_hidden(prompt) do
    # Turn off terminal echo so the password doesn't appear on-screen.
    # Fall back to an echoed prompt if echo toggling isn't supported
    # (e.g. piped stdin during testing).
    IO.write(prompt)

    case :io.setopts(:standard_io, echo: false) do
      :ok ->
        line = IO.gets("") |> to_string() |> String.trim_trailing("\n")
        :io.setopts(:standard_io, echo: true)
        IO.write("\n")
        line

      _ ->
        IO.gets("") |> to_string() |> String.trim_trailing("\n")
    end
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join("\n", fn {field, msgs} -> "  #{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
