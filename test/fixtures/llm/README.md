# LLM replay fixtures

`synthetic_*.json` files are hand-built Req.Test responses, **not real captured model
output**. Their token/cost fields are synthetic test inputs, not provider measurements.
Each has an explicit `.provenance.json` sidecar. Replay serves the listed response
bodies once each and fails if the client asks for an extra response.

Owner-run recording may create genuine provider response files here after the
budgeted eval task is integrated. Never relabel synthetic fixtures as real captures.
No paid calls were used to create these fixtures.
