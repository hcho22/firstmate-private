# Authorized disposable local pilot
Candidate: exact SHA-256 of the workload program; environment: loopback HTTP and isolated SQLite under this directory.
Permitted actions: local unexposed deploy, combined deployment to the internal cohort, internal exposure, all-local exposure, disable, representative failed restoration, and retained-data inspection; never production or live fleet mutation.
Stages: internal then all-local; each needs at least 2 real requests over a 1-second window ending within 60 seconds of assessment.
Measurements identify the current exposure action and start no earlier than its verified external start time; restart retains that attempt after reconciliation.
Health and terminal evidence must match the current plan and latest reconciled effect; measurements and final verification cannot predate that effect.
Stop: any leaked write, unhealthy response, or unavailable monitoring stops expansion.
Recovery: disable gate, issue fresh requests, compare persisted write counts, and retain earlier writes; an acknowledged request alone is insufficient.
Real commands: brief/promotion outputs, installed tasks-axi markdown lifecycle, fm-release consistency check, authenticated fm-check registration, fm-watch, generation-bound wake drain/ack, and owner retirement.
The operator verifies authorization from the accepted test scope; the checker only assesses recorded consistency.
