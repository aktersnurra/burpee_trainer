defmodule BurpeeTrainer.Evals.ProviderGuard do
  @moduledoc "Owner-run evals may use providers; test evals must be demonstrably Req.Test-only."
  def check!(:test, config, %Req.Request{} = request) do
    url = Keyword.get(config, :url)
    host = if is_binary(url), do: URI.parse(url).host
    test_host? = is_binary(host) and String.ends_with?(host, ".test")
    stub? = match?({Req.Test, _}, request.options[:plug])

    unless test_host? and stub?,
      do: Mix.raise("Test eval requires a .test URL and an actual Req.Test plug")

    :ok
  end

  def check!(:test, _config, _request),
    do: Mix.raise("Test eval requires a .test URL and an actual Req.Test plug")

  def check!(_env, _config, _request), do: :ok
end
