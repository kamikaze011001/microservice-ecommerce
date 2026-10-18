package org.aibles.ecommerce.core_replica_routing;

import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Turns {@link ReplicaRead} on a method into "this thread may read a replica"
 * for exactly the duration of that method call.
 *
 * <ul>
 *   <li><b>The guard:</b> inside an active transaction that is NOT read-only the
 *       call is refused. A read inside a read-write transaction is the
 *       check-then-write / load-mutate-save case — it must read the primary.
 *       Annotations get copy-pasted; the guard turns that mistake into a failing
 *       test instead of a stale read.</li>
 *   <li>The flag is on for the call and back to what it was afterwards — returned
 *       or thrown ({@code finally}).</li>
 *   <li><b>Order:</b> highest precedence, so this wraps any {@code @Transactional}
 *       on the same method (the transaction interceptor runs at lowest
 *       precedence). The guard then sees the CALLER's transaction, and the flag is
 *       already on when the method's own read-only transaction opens its
 *       connection.</li>
 * </ul>
 */
@Aspect
@Order(Ordered.HIGHEST_PRECEDENCE)
public class ReplicaReadAspect {

    @Around("@annotation(org.aibles.ecommerce.core_replica_routing.ReplicaRead)")
    public Object aroundReplicaRead(ProceedingJoinPoint pjp) throws Throwable {
        if (TransactionSynchronizationManager.isActualTransactionActive()
                && !TransactionSynchronizationManager.isCurrentTransactionReadOnly()) {
            throw new IllegalStateException("@ReplicaRead " + pjp.getSignature().toShortString()
                    + " called inside a read-write transaction: a read that decides a write must read"
                    + " the primary — remove @ReplicaRead or call it outside the transaction");
        }
        ReplicaContext.enter();
        try {
            return pjp.proceed();
        } finally {
            ReplicaContext.exit();
        }
    }
}
