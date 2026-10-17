# Credo, strict, with ExSlop's checks (from VibeKit).
#
# Baseline: when this gate was adopted (2026-10-17) these files already broke these checks.
# Each check skips only the files listed for it; every other file, and every new file,
# is checked in full. Fixing a file means deleting it from its list.
baseline = %{
  Credo.Check.Readability.AliasOrder => [
    "lib/burpee_trainer/coach.ex",
    "lib/burpee_trainer/coach/agent.ex",
    "lib/burpee_trainer/coach/agent_prompt.ex",
    "lib/burpee_trainer/coach/exchange.ex",
    "lib/burpee_trainer/coach/ledger.ex",
    "lib/burpee_trainer/coach/memory.ex",
    "lib/burpee_trainer/coach/plan_next_workout_job.ex",
    "lib/burpee_trainer/coach/summary.ex",
    "lib/burpee_trainer/coach/tools/history.ex",
    "lib/burpee_trainer/coach/tools/propose_goal.ex",
    "lib/burpee_trainer/coach/tools/propose_workout.ex",
    "lib/burpee_trainer/coach/workout_guidance.ex",
    "lib/burpee_trainer/history.ex",
    "lib/burpee_trainer/home.ex",
    "lib/burpee_trainer/insights.ex",
    "lib/burpee_trainer/insights/metrics.ex",
    "lib/burpee_trainer/insights/narrator.ex",
    "lib/burpee_trainer/mcp/sessions.ex",
    "lib/burpee_trainer/mcp/tools/history_stats.ex",
    "lib/burpee_trainer/mcp/tools/progress.ex",
    "lib/burpee_trainer/mcp/tools/sessions.ex",
    "lib/burpee_trainer/mcp/tools/week.ex",
    "lib/burpee_trainer/mcp/workout_format.ex",
    "lib/burpee_trainer/week_window.ex",
    "lib/burpee_trainer/workouts.ex",
    "lib/burpee_trainer_web.ex",
    "lib/burpee_trainer_web/live/home_authoring.ex",
    "lib/burpee_trainer_web/live/home_chooser.ex",
    "lib/burpee_trainer_web/live/home_live.ex",
    "lib/burpee_trainer_web/live/home_workout_request.ex",
    "lib/burpee_trainer_web/live/home_workspace.ex",
    "test/burpee_trainer/coach/authoring_budget_test.exs",
    "test/burpee_trainer/coach/planner_enqueue_concurrency_test.exs",
    "test/burpee_trainer/coach/planner_selection_test.exs",
    "test/burpee_trainer/coach/propose_workout_test.exs",
    "test/burpee_trainer/coach/summary_job_test.exs",
    "test/burpee_trainer/coach/tools_test.exs",
    "test/burpee_trainer/goals_test.exs",
    "test/burpee_trainer/history_test.exs",
    "test/burpee_trainer/home_test.exs",
    "test/burpee_trainer/insights/completion_admission_test.exs",
    "test/burpee_trainer/insights/narrate_job_test.exs",
    "test/burpee_trainer/insights/narrator_test.exs",
    "test/burpee_trainer/mcp/coach_test.exs",
    "test/burpee_trainer/mcp/history_tools_test.exs",
    "test/burpee_trainer/mcp/memory_goal_tools_test.exs",
    "test/burpee_trainer/mcp/planner_tool_test.exs",
    "test/burpee_trainer/mcp/session_tools_test.exs",
    "test/burpee_trainer/mcp/workout_tools_test.exs",
    "test/burpee_trainer/mcp_test.exs",
    "test/burpee_trainer/workouts/home_recovery_test.exs",
    "test/burpee_trainer/workouts/home_returning_evidence_test.exs",
    "test/burpee_trainer/workouts/home_selection_test.exs",
    "test/burpee_trainer_web/controllers/pose_trace_upload_controller_test.exs",
    "test/burpee_trainer_web/flows/archive_flow_test.exs",
    "test/burpee_trainer_web/flows/coach_permission_flow_test.exs",
    "test/burpee_trainer_web/flows/edit_workout_flow_test.exs",
    "test/burpee_trainer_web/flows/history_summary_flow_test.exs",
    "test/burpee_trainer_web/flows/offline_completion_flow_test.exs",
    "test/burpee_trainer_web/flows/ownership_flow_test.exs",
    "test/burpee_trainer_web/flows/planned_next_workout_flow_test.exs",
    "test/burpee_trainer_web/live/app_flow_test.exs",
    "test/burpee_trainer_web/live/home_authoring_ux_test.exs",
    "test/burpee_trainer_web/live/home_choose_recovery_test.exs",
    "test/burpee_trainer_web/live/home_first_use_test.exs",
    "test/burpee_trainer_web/live/home_live_state_test.exs",
    "test/burpee_trainer_web/live/home_live_test.exs",
    "test/burpee_trainer_web/live/home_returning_mount_test.exs",
    "test/burpee_trainer_web/live/home_revision_test.exs",
    "test/burpee_trainer_web/live/session_live_test.exs",
    "test/burpee_trainer_web/live/summary_refresh_test.exs",
    "test/burpee_trainer_web/live/video_live_test.exs",
    "test/burpee_trainer_web/live/workspace_reentry_test.exs",
    "test/mix/tasks/eval_approval_preview_test.exs"
  ],
  Credo.Check.Readability.LargeNumbers => [
    "lib/burpee_trainer/goals.ex",
    "lib/burpee_trainer/mcp.ex",
    "test/burpee_trainer/insights/fallback_test.exs",
    "test/burpee_trainer/mcp/coach_test.exs",
    "test/burpee_trainer/mcp_test.exs",
    "test/burpee_trainer_web/controllers/mcp_controller_test.exs",
    "test/burpee_trainer_web/flows/archive_flow_test.exs",
    "test/burpee_trainer_web/flows/edit_workout_flow_test.exs",
    "test/burpee_trainer_web/live/history_workspace_test.exs",
    "test/burpee_trainer_web/live/home_live_state_test.exs",
    "test/burpee_trainer_web/live/home_live_test.exs",
    "test/burpee_trainer_web/live/home_revision_test.exs"
  ],
  Credo.Check.Readability.MaxLineLength => [
    "lib/burpee_trainer_web/components/home_history_components.ex"
  ],
  Credo.Check.Readability.ModuleDoc => [
    "lib/burpee_trainer/coach/catalog.ex",
    "lib/burpee_trainer/coach/tools/goals.ex",
    "lib/burpee_trainer/coach/tools/history.ex",
    "lib/burpee_trainer/coach/tools/library.ex",
    "lib/burpee_trainer/coach/tools/propose_goal.ex",
    "lib/burpee_trainer/coach/tools/propose_workout.ex",
    "lib/burpee_trainer/coach/tools/select_workout.ex",
    "lib/burpee_trainer/mcp/tools/coach_context.ex",
    "lib/burpee_trainer/mcp/tools/goals.ex",
    "lib/burpee_trainer/mcp/tools/history_stats.ex",
    "lib/burpee_trainer/mcp/tools/memory.ex",
    "lib/burpee_trainer/mcp/tools/plan_next_workout.ex",
    "lib/burpee_trainer/mcp/tools/progress.ex",
    "lib/burpee_trainer/mcp/tools/query_history.ex",
    "lib/burpee_trainer/mcp/tools/sessions.ex",
    "lib/burpee_trainer/mcp/tools/set_coach_note.ex",
    "lib/burpee_trainer/mcp/tools/week.ex",
    "lib/burpee_trainer/mcp/tools/workouts.ex",
    "lib/burpee_trainer/workouts/home_selection.ex",
    "lib/burpee_trainer_web/components/home_workout_components.ex",
    "lib/mix/tasks/burpee_trainer.add_video.ex",
    "lib/mix/tasks/burpee_trainer.eval.ex",
    "test/support/isolated_migration_repo.ex"
  ],
  Credo.Check.Readability.ParenthesesOnZeroArityDefs => [
    "lib/burpee_trainer/application.ex"
  ],
  Credo.Check.Readability.StringSigils => [
    "lib/burpee_trainer_web/fmt.ex"
  ],
  Credo.Check.Readability.WithSingleClause => [
    "lib/burpee_trainer/coach.ex",
    "lib/burpee_trainer/coach/authoritative_session.ex",
    "lib/burpee_trainer/home.ex",
    "lib/burpee_trainer/workouts.ex",
    "lib/burpee_trainer_web/live/history_screen.ex"
  ],
  Credo.Check.Refactor.Apply => [
    "test/burpee_trainer/schema_migration_test.exs"
  ],
  Credo.Check.Refactor.CondStatements => [
    "lib/burpee_trainer/coach/catch_up_policy.ex",
    "lib/burpee_trainer/insights/validator.ex",
    "lib/burpee_trainer_web/fmt.ex",
    "lib/burpee_trainer_web/live/home_chooser.ex"
  ],
  Credo.Check.Refactor.CyclomaticComplexity => [
    "lib/burpee_trainer/accounts.ex",
    "lib/burpee_trainer/coach/agent.ex",
    "lib/burpee_trainer/coach/tools/propose_goal.ex",
    "lib/burpee_trainer/coach/workout_request.ex",
    "lib/burpee_trainer/evals/options.ex",
    "lib/burpee_trainer/goals.ex",
    "lib/burpee_trainer/workouts.ex",
    "lib/burpee_trainer_web/live/home_chooser.ex",
    "lib/burpee_trainer_web/live/home_live.ex"
  ],
  Credo.Check.Refactor.FilterFilter => [
    "lib/burpee_trainer/levels.ex",
    "lib/burpee_trainer/week_window.ex"
  ],
  Credo.Check.Refactor.MapJoin => [
    "test/support/fixtures.ex"
  ],
  Credo.Check.Refactor.MatchInCondition => [
    "lib/burpee_trainer/workouts.ex"
  ],
  Credo.Check.Refactor.Nesting => [
    "lib/burpee_trainer/accounts.ex",
    "lib/burpee_trainer/coach.ex",
    "lib/burpee_trainer/coach/agent.ex",
    "lib/burpee_trainer/coach/client.ex",
    "lib/burpee_trainer/coach/plan_next_workout_job.ex",
    "lib/burpee_trainer/coach/workout_request.ex",
    "lib/burpee_trainer/evals/approval_preview.ex",
    "lib/burpee_trainer/goals.ex",
    "lib/burpee_trainer/history.ex",
    "lib/burpee_trainer/insights.ex",
    "lib/burpee_trainer/insights/narrator.ex",
    "lib/burpee_trainer/mcp/sessions.ex",
    "lib/burpee_trainer/mcp/tools/history_stats.ex",
    "lib/burpee_trainer/mcp/tools/query_history.ex",
    "lib/burpee_trainer/plan_compiler/workout_definition.ex",
    "lib/burpee_trainer/workouts.ex",
    "lib/burpee_trainer/workouts/inspection.ex",
    "lib/burpee_trainer_web/components/home_history_components.ex",
    "lib/burpee_trainer_web/live/history_screen.ex",
    "lib/burpee_trainer_web/live/home_chooser.ex",
    "lib/burpee_trainer_web/live/home_live.ex",
    "test/burpee_trainer/schema_migration_test.exs",
    "test/support/replay_provider.ex"
  ],
  Credo.Check.Refactor.RedundantWithClauseResult => [
    "lib/burpee_trainer/evals/runner.ex",
    "lib/burpee_trainer/plan_compiler/program_validator.ex"
  ],
  Credo.Check.Warning.OperationOnSameValues => [
    "lib/burpee_trainer/coach/rest_fitter.ex"
  ],
  Credo.Check.Warning.UnusedEnumOperation => [
    "test/burpee_trainer/coach/rest_fitter_test.exs"
  ],
  ExSlop.Check.Refactor.IdentityPassthrough => [
    "lib/burpee_trainer/workouts.ex"
  ],
  ExSlop.Check.Refactor.LengthComparison => [
    "lib/burpee_trainer/coach/client.ex",
    "lib/burpee_trainer/coach/policy.ex",
    "lib/burpee_trainer/coach/workout_request.ex",
    "lib/burpee_trainer/insights/validator.ex",
    "lib/burpee_trainer/workouts/pace_consistency.ex",
    "test/burpee_trainer/accounts_test.exs",
    "test/burpee_trainer/coach/memory/ops_test.exs",
    "test/burpee_trainer/coach/plan_next_workout_job_test.exs",
    "test/burpee_trainer/coach/suggestions_test.exs",
    "test/burpee_trainer/e2e_library_setup_test.exs",
    "test/burpee_trainer/history_test.exs",
    "test/burpee_trainer/insights/narrate_job_test.exs",
    "test/burpee_trainer/mcp/workout_tools_test.exs",
    "test/burpee_trainer/plan_compiler/program_test.exs",
    "test/burpee_trainer/workouts/inspection_test.exs",
    "test/burpee_trainer/workouts/recent_training_sessions_test.exs",
    "test/burpee_trainer_web/flows/planned_next_workout_flow_test.exs",
    "test/burpee_trainer_web/live/home_day_boundary_test.exs",
    "test/burpee_trainer_web/live/home_live_test.exs",
    "test/burpee_trainer_web/live/summary_refresh_test.exs",
    "test/mix/tasks/eval_scenarios_test.exs"
  ],
  ExSlop.Check.Warning.DualKeyAccess => [
    "lib/burpee_trainer/workouts.ex"
  ],
  ExSlop.Check.Warning.PathExpandPriv => [
    "test/burpee_trainer/coach_memory_retirement_migration_test.exs",
    "test/burpee_trainer/coach_settings_retirement_migration_test.exs",
    "test/burpee_trainer/schema_migration_test.exs",
    "test/burpee_trainer/starter_workouts_migration_test.exs"
  ],
  ExSlop.Check.Warning.RepoAllThenFilter => [
    "lib/burpee_trainer/coach/policy.ex"
  ]
}

%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      checks:
        [
          {Credo.Check.Design.AliasUsage, false},
          {ExSlop.Check.Readability.NarratorDoc, false}
        ] ++
          Enum.map(baseline, fn {check, files} -> {check, files: %{excluded: files}} end)
    }
  ]
}
