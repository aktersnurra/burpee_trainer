defmodule BurpeeTrainer.Evals.Runner do
  @moduledoc "Budgeted real authoring evaluation with one owned identity and run UUID. No provider I/O inside approval preview transactions."
  import Ecto.Query
  alias BurpeeTrainer.{Coach, Repo}
  alias BurpeeTrainer.Coach.LlmCall
  alias BurpeeTrainer.Evals.{ApprovalPreview, Owner, ProviderGuard, Recorder, Results, Scenarios}

  def run(%{max_calls: cap} = options, opts \\ []) when is_integer(cap) and cap > 0 do
    config = Keyword.get(opts, :config, Application.get_env(:burpee_trainer, :llm_provider, []))
    req = Keyword.get_lazy(opts, :req, &Req.new/0)
    ProviderGuard.check!(Mix.env(), config, req)

    scenarios =
      Keyword.get_lazy(opts, :scenarios, fn -> Scenarios.load!(options.suite, options.only) end)

    run_id = Ecto.UUID.generate()
    root = Keyword.get(opts, :output_dir, ".e2e-artifacts/evals")
    File.mkdir_p!(root)
    prefix = Path.join(root, "#{System.system_time(:microsecond)}-#{run_id}")

    result =
      Owner.with_owner(fn scope ->
        owner = %{id: scope.user.id, username: scope.user.username}
        File.write!(prefix <> ".owner.json", Jason.encode!(owner, pretty: true) <> "\n")

        rows =
          Enum.map(scenarios, fn scenario ->
            before = calls(scope, run_id)
            {:ok, recorder} = Agent.start_link(fn -> [] end)

            try do
              request = if options.record, do: Recorder.attach(req, recorder), else: req

              outcome =
                with {:ok, input} <- Scenarios.prepare(scenario),
                     {:ok, prepared} <-
                       Coach.prepare_plan(scope, input.instruction, input.request,
                         req: request,
                         config: config,
                         run_id: run_id,
                         budget: [run_cap: cap]
                       ),
                     {:ok, facts} <- ApprovalPreview.validate(scope, prepared),
                     do: {:ok, facts}

              measured = Enum.drop(calls(scope, run_id), length(before))

              if options.record do
                Recorder.write!(
                  Keyword.get(opts, :recordings_dir, "test/fixtures/llm"),
                  scenario["id"],
                  Recorder.responses(recorder),
                  %{
                    capture_kind:
                      if(match?({Req.Test, _}, req.options[:plug]),
                        do: "synthetic_req_test",
                        else: "provider_response"
                      ),
                    scenario_id: scenario["id"],
                    run_id: run_id,
                    model: config[:model]
                  }
                )
              end

              Results.scenario(scenario["id"], outcome, measured)
              |> Map.merge(
                case outcome do
                  {:ok, facts} -> facts
                  _ -> %{approval_validated: false, publication_rolled_back: false}
                end
              )
            after
              Agent.stop(recorder)
            end
          end)

        %{
          run_id: run_id,
          owner: owner,
          scenarios: rows,
          total: Results.total(rows),
          calls:
            Enum.map(
              calls(scope, run_id),
              &Map.take(&1, [
                :id,
                :user_id,
                :run_id,
                :purpose,
                :model,
                :prompt_tokens,
                :completion_tokens,
                :cost_usd,
                :outcome,
                :duration_ms
              ])
            ),
          output_path: prefix <> ".json"
        }
      end)

    result = Map.put(result, :owner_cleaned, true)
    File.write!(result.output_path, Jason.encode!(result, pretty: true) <> "\n")
    result
  end

  defp calls(scope, run_id) do
    Repo.all(
      from call in LlmCall,
        where: call.user_id == ^scope.user.id and call.run_id == ^run_id,
        order_by: [asc: call.id]
    )
  end
end
