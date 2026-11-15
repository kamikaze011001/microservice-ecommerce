---
name: proof-invariants-follow-workload-and-state-machine
description: Before writing a proof's invariant, read the load script's mix and the saga's state machine — "all COMPLETED"/"none PROCESSING" are wrong for this app by design
metadata: { type: convention, date: 2026-10-10 }
---
`make devbox-env-proof` failed twice while the system was correct:
- **"Every order COMPLETED" was wrong.** `deploy/k6-stress/payment-flow.js` approves 90%, cancels 5% and fails 5% of payments on purpose.
- **"None PROCESSING" was wrong.** A PayPal *cancel* abandons the payment attempt, not the order. The saga stays AWAITING_PAYMENT for a retry until `application.saga.saga-ttl-minutes` (30) expires it (`SagaOrchestrationServiceImpl` handles `PaymentCanceledEvent`).

The correct invariant: every PROCESSING order has a saga that is AWAITING_PAYMENT, not yet expired, with a CANCELED payment and no SUCCESS or PROCESSING payment. Any other PROCESSING order is "unexplained" and fails the check.

**Why:** this is the mirror image of [[deploy-checks-assert-digest-not-tag]] (a proof that passed while proving nothing). An assertion that doesn't match the designed behaviour either hides bugs or cries wolf, and both erode trust in the proof.

**How to apply:**
- For any order or saga invariant (chaos-proof, env-proof, future k6 checks), read the workload's decision mix and the saga state machine first.
- Assert "every non-terminal state is a *designed* waiting state". Don't assert "everything is terminal".

Related: [[0011-devbox-local-gitops-platform]].
