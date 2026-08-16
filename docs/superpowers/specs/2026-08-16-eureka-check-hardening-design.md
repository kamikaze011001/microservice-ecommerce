# Eureka Freshness Check — Hardening

Two follow-ups parked with rulings during PR #60 (`fix/phase8-followups`). Both concern
`scripts/lib/eureka.sh` and its caller `scripts/services/start.sh`, which decide whether an
already-running service is serving a stale Eureka registration and must be restarted.

Neither is reachable today. Both are the kind that get harder to fix later.

---

## 1. Fix A — the suite gates a function production does not call

### The problem

`eureka.sh` exports `registration_is_stale <port>`. **Only `scripts/lib/tests/eureka-test.sh`
calls it.** `start_one()` re-implements the same formula inline
(`scripts/services/start.sh:136-142`):

```bash
_host_ip=$(current_host_ip) || _host_ip=""
_reg_ip=$(eureka_registered_ip "$_port") || _reg_ip=""
if [ -n "$_port" ] && [ -n "$_host_ip" ] && [ -n "$_reg_ip" ] && [ "$_reg_ip" != "$_host_ip" ]; then
```

The duplication was deliberate and disclosed: `start_one` needs the two IPs for its log line,
and calling `registration_is_stale` *then* fetching them separately would double the Eureka
round-trip per service — a finding raised and fixed earlier in that same PR.

The consequence is what matters. **A green suite says nothing about the shipped path.** The
review that "proved the suite can fail" perturbed `registration_is_stale` — the function
production never runs. Breaking `start.sh:142` leaves the suite at 6/0.

This also explains a minor logged separately: `deploy/README.md` attributes the check to
`registration_is_stale()`. The doc describes the algorithm correctly; the code duplicated it.

### The fix

`eureka.sh` exports one function that returns the verdict **and** the values:

```
eureka_staleness <http_port>
  stdout : "<reg_ip> <host_ip>"   (only meaningful on exit 0)
  exit 0 : STALE
  exit 1 : not stale, OR unknown
```

`start_one` calls it once and reads both values for its log message. One Eureka round-trip,
one implementation, and the test exercises the code that ships.

`registration_is_stale` is **removed**, not kept as a wrapper — a wrapper nothing calls is the
same trap one indirection further out.

*Rejected:* having `registration_is_stale` set globals (`EUREKA_REG_IP`/`EUREKA_HOST_IP`) —
works in bash but abandons the file's stated "pure query + comparison" design, and a caller
that forgets to read them gets the previous call's values. *Also rejected:* testing
`start.sh`'s path directly — it would need a live stack, and the whole point of the fixture
suite is that it runs with everything down.

---

## 2. Fix B — equality against one interface is the wrong question

### The problem

`current_host_ip` derives the host IP from the **default route**:

```bash
iface=$(route -n get default | awk '/interface:/{print $2}')
ip=$(ipconfig getifaddr "$iface")
```

Spring registers whatever **`InetUtils`** picks — the first non-loopback site-local address by
interface enumeration order (`eureka.instance.prefer-ip-address: true`, no explicit
`ip-address`).

These are different questions with the same answer *on this host, today*. It has **five**
non-loopback site-local addresses:

```
192.168.0.103   en1 — the default route, and what Eureka currently holds
192.168.117.0   docker / minikube bridges
192.168.139.3
192.168.147.0
192.168.49.0
```

If enumeration order ever puts a bridge address first, the check yields a **non-empty wrong
answer**. Every fail-safe in this code guards against *empty*; none guards against *wrong*. The
result is permanent: every service is declared stale on every `make up`, restarted, and
re-registers the same InetUtils address, so the next run does it again.

### The fix

Stale becomes **"the registered IP is not any of this host's local IPv4 addresses"** rather
than "differs from the default-route IP".

If Spring registered any address this host owns, that is a different interface, not drift.
The failure direction inverts to the safe one: a genuinely stale registration whose old
address is still assigned somewhere reads as fresh, and the check does nothing — matching
every other fail-safe here.

`HOST_IP_OVERRIDE` is reinterpreted as **"pretend the local set is exactly this one IP"**, so
`HOST_IP_OVERRIDE=10.0.0.7` still forces drift and the existing tests keep their meaning.

*Rejected:* replicating `InetUtils`' selection algorithm — couples this script to Spring
internals that can change under us, and gets us back to comparing one guess against another.

---

## 3. Scope

**In:** `scripts/lib/eureka.sh`, `scripts/services/start.sh`'s skip branch,
`scripts/lib/tests/eureka-test.sh`, and the `deploy/README.md` sentence that names
`registration_is_stale`.

**Out:** everything else parked from PR #60 — no `status == "UP"` filter, no `proc.sh` test
coverage, `proc.sh`'s use of `log_warn` without sourcing `colors.sh`, the `sleep 1` before
SIGKILL, and the `kind`→minikube drift in the teaching pages. Recorded, not silently skipped.

---

## 4. Verification

The decision table gains two rows that fail against today's code:

| condition | expected |
|---|---|
| registered IP is a local address that is **not** the default-route one | **not stale** — today this is a false "stale", forever |
| `eureka_staleness` returns both IPs on stdout when stale | values usable for the log without a second query |

The existing rows must all still hold, including both fail-safes (Eureka unreachable, host IP
undeterminable → not stale, asserted as explicit non-stale verdicts rather than inferred from
"nothing happened").

**The mutation test moves onto `eureka_staleness`.** Perturbing it must fail the suite —
that is the property Fix A exists to restore, so it is verification, not ceremony.

Live: `make up` twice on an unchanged network restarts nothing; `HOST_IP_OVERRIDE` forces
exactly the registered services and no others.

---

## 5. Risks

- **Fix B makes the check less eager.** That is the intent, and it is the direction every
  other guard here already leans — but it does mean a host holding a stale address on some
  other interface will not be healed automatically. `make svc-restart` remains the
  unconditional remedy.
- **Enumerating local addresses is platform-specific.** `ifconfig` output parsing is macOS/BSD
  shaped; the existing `route`/`ipconfig` calls already are. This does not make the script
  less portable than it is today, but it does not improve it either.
- **`start.sh` is the daily loop.** A wrong verdict is felt on every `make up`. The live
  verification is not optional.
