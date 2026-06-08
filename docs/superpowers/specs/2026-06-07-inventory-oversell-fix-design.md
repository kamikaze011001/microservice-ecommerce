# Inventory Oversell Fix — Design Spec

**Status:** SPEC ONLY — implementation parked. Implement fresh via `writing-plans` → `subagent-driven-development`.
**Date:** 2026-06-07
**Scope:** close the stock-oversell race in the payment saga so committed stock can never exceed available stock.

---

## 1. Problem

Under concurrent load at the stock boundary, the payment saga **oversells**: `SUM(product_quantity_history)` for a product goes **negative**. Reproduced deterministically: seed a product to 60 units, drive 50 concurrent VUs (all-approve) at it, let the saga settle → **`final_stock = -1`** (61 committed against 60).

## 2. Confirmed root cause (systematic-debugging)

The reservation is an atomic Redis Lua script (`CHECK_AND_RESERVE_LUA_SCRIPT` in `core-order-cache`): it checks `currentQueued(reserved) + requested ≤ maxInventory` for all products, then `INCRBY` reserves them. **The Lua itself is correct** (all-or-nothing; `reserved` read fresh inside the script).

The bug is that **`maxInventory` (the stock ceiling) is read *outside* the Lua and passed in as a snapshot** — produced by `order-service` calling inventory gRPC `list()` → `SUM(product_quantity_history)`.

Investigation results:
- **Replication lag (first hypothesis):** that SUM was read from a **slave** (`slaveProductQuantityHistoryRepo`) while decrements write to **master** → async-replica staleness made the snapshot stale-high. Fixed in commit `4fda72f` (route the SUM to master). **This did NOT fix the oversell** — boundary test still `-1`.
- **Cleanup race:** ruled out — `ExpiredOrderCleanupJob` uses a 24-hour expiry and a 30-min schedule; it fired during the test and found "No expired orders."
- **Actual mechanism (confirmed):** even read fresh from master, `maxInventory` is a **snapshot taken before the Lua runs**. Between the gRPC read and the Lua's `INCRBY`, in-flight payment commits reduce real stock; the Lua decides against the stale snapshot. **TOCTOU by construction.**

The math: a grant occurs when `reserved_now + 1 ≤ maxInventory`. With `reserved_now ≈ reserved_ever − committed` and `maxInventory = S − committed_at_read_time`, the `committed` terms cancel →

```
reserved_ever + 1 ≤ S + (commits that landed between the read and the Lua)
```

So the cap **leaks by the number of payment-commits in the read→Lua gap**. The master-read fix removed *replication* lag, shrinking the gap to one gRPC→Lua round-trip (~1 commit at 27 commits/s) — hence `-1`, not a larger overshoot.

**Conclusion:** any stock value read *outside* the atomic reserve is stale the instant another commit lands. Correctness requires the stock check **and** decrement to be a single atomic operation against an authoritative counter. No snapshot can ever be safe.

## 3. Design — authoritative stock inside the atomic op (+ DB floor)

### 3.1 Invert the Redis counter: reserved → available

Today Redis holds a **reserved** counter (`QUEUE_PRODUCT_KEY:{pid}`): `INCRBY` on reserve, `decr` on commit/release, checked against an external `maxInventory`. Replace it with an **available** counter that is itself the source of truth for reservations:

- **Key:** `available:{productId}` = units currently available to reserve.
- **Reserve (Lua, self-contained — no `maxInventory` argument):**
  ```
  for each product i:  if (GET available[i]) < need[i] then return 0   -- abort, all-or-nothing
  for each product i:  DECRBY available[i] need[i]
  return 1
  ```
  Check and decrement happen in one atomic Lua call → no external snapshot → no TOCTOU.
- **Release** (order cancel / payment fail / saga compensation / expiry cleanup): `INCRBY available[i] need[i]`.
- **Commit** (payment success): **does NOT touch `available`** — the unit was already removed at reserve time. (This is the key behavioral change: today's commit path `decr`s the counter; under the new model it must not.)
- **Replenish** (admin top-up / restock): `INCRBY available[i] delta` **and** write the DB ledger.

### 3.2 DB conditional floor (system-of-record authority + recovery)

Redis is the fast path; the DB must still be unable to oversell and must be able to reseed Redis:

- At payment-success decrement, enforce a hard floor in the DB. Recommended: a materialized `stock` column on `inventory_product` updated with an atomic conditional `UPDATE inventory_product SET stock = stock - :n WHERE id = :id AND stock >= :n` (0 rows ⇒ would-oversell ⇒ alert/compensate). (Alternative: keep the append-only ledger and add a guard, but a materialized column gives a clean atomic conditional — see Open Decisions.)
- This column is the **recovery source**: on inventory-service boot, reseed `available:{pid}` from authoritative DB stock minus outstanding reservations.

### 3.3 Seeding & recovery

- **Boot:** initialize `available:{pid}` from the DB. Clean boot with no in-flight orders ⇒ `available = sellable stock`.
- **Redis loss/restart:** `available` is gone → reseed from the DB floor on next boot; until reseeded, reserves fail closed (reject) rather than oversell.

## 4. Affected components / files

- **`core/core-order-cache`** — rewrite `CHECK_AND_RESERVE_LUA_SCRIPT` (drop `maxInventory`; check+`DECRBY available`); add release/replenish/seed operations; rename `QUEUE_PRODUCT_KEY` semantics (reserved → available) or introduce `AVAILABLE_PRODUCT_KEY`.
- **`order-service`** (`OrderServiceImpl.validateAndReserveInventoryAtomic`) — stop fetching/passing `maxInventory`; call the self-contained reserve. Keep the rollback-on-failure path but as `INCRBY available` (release). `ExpiredOrderCleanupJob` release → `INCRBY available`.
- **`inventory-service`** (`InventoryServiceImpl`) — `handleSuccessPayment`/`processInventoryUpdate`: keep the DB ledger decrement, add the DB conditional floor, and **remove the Redis counter decrement on commit**. `update()` (admin) adjusts `available` + DB. Add `available` seeding on startup. Optional `inventory_product.stock` column.

## 5. Data flow

| Event | Redis `available` | DB |
|---|---|---|
| order-create reserve | atomic check + `DECRBY` | — (order row created) |
| payment success (commit) | **unchanged** | ledger decrement, conditional `>= 0` |
| cancel / fail / compensate / expiry | `INCRBY` (release) | — |
| admin replenish / restock | `INCRBY` (delta) | ledger add |
| inventory boot | seed from DB | (read) |

## 6. Edge cases / error handling

- **Multi-product order:** Lua checks ALL then decrements ALL (preserve the existing all-or-nothing semantics).
- **Reserve→create-order failure:** existing rollback releases the reservation (`INCRBY`) — keep, ensure idempotent.
- **Double-release:** tie release to order state so cancel + cleanup can't both release the same reservation.
- **Redis loss:** reseed from DB; fail-closed meanwhile.
- **Idempotency of commit:** keep the existing processed-event dedup (MongoDB unique `(orderId,eventType)`).

## 7. Testing

- **Regression (must pass):** the committed boundary test `k8s/apps/base/k6-stress/oversell-boundary-flow.js` + `oversell-boundary-job.yaml` — seed a product low (~60), create the `k6-oversell-script` configmap from the script, run the Job (50 VUs all-approve), settle, then `SELECT SUM(quantity) FROM product_quantity_history WHERE product_id=<target>` must floor at **0**, never negative. This is the exact reproduction that currently yields `-1`. (Consider promoting to a `make` target during implementation.)
- **Unit:** Lua check-and-decrement never drops `available` below 0 under concurrent calls.
- **DB floor:** conditional decrement rejects below 0.

## 8. Prerequisite already shipped

Commit `4fda72f` (route the reservation SUM read to master) is a **prerequisite / partial mitigation**, not the fix: it removes replication-lag staleness and is consistent with making stock authoritative, but the TOCTOU snapshot gap remains. **Do not describe `4fda72f` as "the oversell fix."** Keep it; build C on top.

## 9. Open decisions (resolve during planning)

1. **DB floor mechanism:** materialized `inventory_product.stock` column with atomic conditional `UPDATE` (recommended — clean atomic check) vs. a guard over the append-only ledger.
2. **Browse reads:** `4fda72f` routed the shared `inventoryService.list()` SUM to master, so storefront/cart **display** also reads master. Decide whether to keep that or split a slave-backed read for browse once `available` (Redis) becomes the reservation authority (display no longer needs the master SUM).
3. **Counter naming/migration:** reuse `QUEUE_PRODUCT_KEY` with inverted semantics vs. introduce `AVAILABLE_PRODUCT_KEY` and migrate.
