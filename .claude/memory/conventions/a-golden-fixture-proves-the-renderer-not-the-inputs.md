---
name: a-golden-fixture-proves-the-renderer-not-the-inputs
description: the pre-flight audit certified mail as CONFIGURED for ENV=aws by reading a golden generated from test fixtures; the real run failed on an unset APPLICATION_MAIL_USERNAME
metadata: { type: convention, date: 2026-08-28 }
---

The AWS pre-flight audit was asked whether mail was configured for `ENV=aws`, because
acceptance tier 3 (registration and login by OTP) depends on it. It answered
**CONFIGURED**, citing all seven `spring.mail.*` keys resolving to non-empty values in
`deploy/secrets/tests/golden/aws.json`.

The live run then failed:

```
secrets-resolve: ecommerce.yaml: key 'spring.mail.username':
environment variable 'APPLICATION_MAIL_USERNAME' is not set
```

That golden is generated from `deploy/secrets/tests/fixtures/user-creds.env`. It
proves the **resolver renders correctly given inputs**. It says nothing whatever about
whether the inputs exist at runtime — and `deploy/scripts/secrets-seed.sh` sources no
env file, expecting them already exported.

**The verdict was not wrong about the file; it was wrong about the question.** "Is
mail configured?" was answered by checking the machine rather than the fuel.

**How to apply:** a golden, fixture, or snapshot is evidence about the *transformation*
only. When the question is "will this work at runtime", trace back to where the real
inputs come from and verify *those* — for this repo, `${VAR}` references in
`deploy/secrets/*.yaml` resolved against the operator's exported environment, which
`up-all.sh:97-112` checks with `need` and nothing else does.

A useful test for any "verified" claim: **if the thing under test were entirely
absent, would this check still pass?** Here it would — the golden is committed and
would render identically with no environment set at all. Related:
[[a-test-may-exercise-code-production-never-calls]],
[[an-oracle-can-validate-a-command-nobody-runs]].
