# Golden inputs and expected outputs for plan generation. Outputs were
# captured after the MILP rewrite. Each expected total duration is within
# ±1s of the input target.
[
  %{
    name: "even, 50 reps, 10 min",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g1",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 50,
      sec_per_burpee: 5.0,
      pacing_style: :even
    },
    expect: %{block_count: 1, total_sets: 1, total_reps: 50, duration_sec: 600}
  },
  %{
    name: "even, 50 reps, 10 min, one rest at min 5",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g2",
      burpee_type: :six_count,
      target_duration_min: 10,
      burpee_count_target: 50,
      sec_per_burpee: 5.0,
      pacing_style: :even,
      additional_rests: [%{rest_sec: 60, target_min: 5}]
    },
    expect: %{block_count: 2, total_sets: 2, total_reps: 50, duration_sec: 600}
  },
  %{
    name: "unbroken, 20 reps x 5 per set, 6 min",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g3",
      burpee_type: :six_count,
      target_duration_min: 6,
      burpee_count_target: 20,
      sec_per_burpee: 5.0,
      pacing_style: :unbroken,
      reps_per_set: 5
    },
    expect: %{block_count: 1, total_sets: 4, total_reps: 20, duration_sec: 360}
  },
  %{
    name: "navy_seal, even, 25 reps, 4 min",
    input: %BurpeeTrainer.PlanWizard.PlanInput{
      name: "g4",
      burpee_type: :navy_seal,
      target_duration_min: 4,
      burpee_count_target: 25,
      sec_per_burpee: 9.0,
      pacing_style: :even
    },
    expect: %{block_count: 1, total_sets: 1, total_reps: 25, duration_sec: 240}
  }
]
