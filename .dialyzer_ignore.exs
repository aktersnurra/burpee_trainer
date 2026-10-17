# Dialyzer warnings that are wrong, each with why. Never add one to get a change through;
# `list_unused_filters` reports an entry once it no longer matches.
[
  # Oidcc types a token's id as `Id.t() | none`; in a typespec `none` is the empty type, not
  # the atom `:none` it returns without an ID token, so the clause for that looks unreachable.
  {"lib/burpee_trainer/auth/oidc.ex", :pattern_match},
  # Ecto.Multi keeps its names in a MapSet, whose opaque type Dialyzer trips over in
  # `Multi.new() |> Multi.run(...)`.
  {"lib/burpee_trainer/workouts.ex", :call_without_opaque}
]
