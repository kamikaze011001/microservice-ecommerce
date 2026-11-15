---
name: mockito-strict-stubs-make-expect-throw-tests-false-green
description: under MockitoExtension strict stubs, calling an overload with different args throws PotentialStubbingProblem — an "expect an exception" test then passes for the wrong reason
metadata: { type: convention, date: 2026-10-08 }
---

`EventListenerHandlerTest.brokerRejectsSend…` stubbed `send(topic, key, record)` and asserted
the handler throws. Production still called the 2-arg `send(topic, record)` — same method name,
different args — so Mockito's strict stubbing threw `PotentialStubbingProblem`, and
`assertThatThrownBy(...)` was satisfied by *Mockito's* exception. The test was green before any
code was written.

The same mechanism also fails tests the other way: a strict stub on one topic, followed by a
send to another topic, aborts the test (`handleSuccess_inventoryNotifyFails` hit this).

**Why:** strict stubs treat "same method, different args" as a probable test bug and throw at call time.

**How to apply:** for multi-call scenarios use `lenient().when(...)`; in expect-throw tests assert
on *what* was thrown (`hasStackTraceContaining("broker down")`), not just that something was.
Check every new red test fails for the intended reason before handing it over. Related: [[a-test-may-exercise-code-production-never-calls]].
