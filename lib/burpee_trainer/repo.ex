defmodule BurpeeTrainer.Repo do
  use Ecto.Repo,
    otp_app: :burpee_trainer,
    adapter: Ecto.Adapters.SQLite3
end
