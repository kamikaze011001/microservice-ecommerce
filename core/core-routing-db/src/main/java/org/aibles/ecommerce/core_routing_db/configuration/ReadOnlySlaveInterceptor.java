package org.aibles.ecommerce.core_routing_db.configuration;

import org.hibernate.Interceptor;
import org.hibernate.type.Type;

/**
 * Makes a slave (read) persistence context query-only.
 *
 * Hibernate calls {@link #findDirty} for every managed entity during a flush.
 * Returning an empty array (rather than {@code null} = "use default dirty
 * checking") tells Hibernate that no property changed, so it never emits an
 * UPDATE on the slave connection.
 *
 * Why this is needed: a slave-loaded entity that is mutated and then written via
 * a master repository is flushed on BOTH the slave and master XA branches. When
 * master and slave datasources point at the same physical MySQL (e.g. the local
 * k8s setup, where they are two Services over one pod), the two UPDATEs
 * self-deadlock on the same row — branch A holds the row's X-lock while its XA
 * commit is in flight, branch B waits the full innodb_lock_wait_timeout (50s) and
 * dies with error 1205, rolling the whole transaction back.
 *
 * A read-replica session must never write; this enforces it regardless of flush
 * mode or transaction manager. (FlushMode.MANUAL is NOT honored under Atomikos
 * JTA — Spring/JPA reset the session back to AUTO — which is why setting the
 * flush mode alone does not work.)
 */
public class ReadOnlySlaveInterceptor implements Interceptor {

    private static final int[] NOTHING_DIRTY = new int[0];

    @Override
    public int[] findDirty(Object entity, Object id, Object[] currentState,
                           Object[] previousState, String[] propertyNames, Type[] types) {
        return NOTHING_DIRTY;
    }
}
