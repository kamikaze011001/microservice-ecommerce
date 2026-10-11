package org.aibles.ecommerce.core_replica_routing;

import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Aspect;

/**
 * Turns {@link ReplicaRead} on a method into "this thread may read a replica"
 * for exactly the duration of that method call.
 *
 * <p>TODO(you) — behaviour the tests pin (ReplicaReadAspectTest):
 * <ul>
 *   <li>advises every method annotated {@link ReplicaRead} on a Spring bean;</li>
 *   <li>inside the call {@link ReplicaContext#isOn()} is true; after it — returned
 *       OR thrown — it is back to what it was before;</li>
 *   <li><b>the guard</b>: if the call happens inside an active transaction that is
 *       NOT read-only, refuse it with {@link IllegalStateException} before the
 *       method body runs. A read inside a read-write transaction is the
 *       check-then-write / load-mutate-save case — it must read the primary;</li>
 *   <li>inside a read-only transaction, or with no transaction at all, it's allowed;</li>
 *   <li>it must wrap the method from OUTSIDE any @Transactional on the same method,
 *       so the guard sees the caller's transaction, and the flag is already on
 *       when the method's own (read-only) transaction opens its connection.</li>
 * </ul>
 * Why the guard and not just a convention: annotations get copy-pasted. The
 * guard turns a stale-read bug into a failing test.
 */
@Aspect
public class ReplicaReadAspect {

    public Object aroundReplicaRead(ProceedingJoinPoint pjp) throws Throwable {
        throw new UnsupportedOperationException("TODO(you): ReplicaReadAspect");
    }
}
