defmodule BurpeeTrainer.TestFixtures.DeletionFirstFallback do
  @moduledoc false

  @definition_json Jason.decode!(
                     ~S|{"burpee_type":"six_count","events":[{"kind":"work","reps":10,"sec_per_burpee":12.0,"sec_per_rep":12.0}],"name":"Built-in Steady 10","pacing_style":"even","rationale":"A steady reusable fallback that works without provider credentials.","target_duration_sec":120,"target_reps":10,"version":1}|
                   )
  @definition_hash "3f3fe32fe29452baa76ea5ba52a3559f1e2e0c84a3c7beb7fe289a67ce271b02"
  @program_json Jason.decode!(
                  ~S|{"burpee_type":"six_count","events":[{"duration_sec":120.0,"kind":"work","reps":10,"sec_per_burpee_us":12000000,"sec_per_rep_us":12000000}],"schema_version":3,"semantics":{"definition_hash":"3f3fe32fe29452baa76ea5ba52a3559f1e2e0c84a3c7beb7fe289a67ce271b02","pacing_style":"even"},"solver_version":1,"target_duration_ms":120000,"target_reps":10}|
                )
  @content_hash "0b39f19b165d83aed946acea3071e3bffacb61861d208bd87f29b327e03a9202"

  def definition_json, do: @definition_json
  def definition_hash, do: @definition_hash
  def program_json, do: @program_json
  def content_hash, do: @content_hash
end
