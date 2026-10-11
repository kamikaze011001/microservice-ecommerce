package org.aibles.ecommerce.core_replica_routing;

/**
 * "Is the current thread inside a {@link ReplicaRead} method?" — the one bit of
 * state the aspect writes and the inspector reads.
 *
 * <p>TODO(you) — behaviour the tests pin (ReplicaContextTest):
 * <ul>
 *   <li>off by default, per thread (one request's flag never leaks into another
 *       thread — the servers reuse threads);</li>
 *   <li>{@code enter()} / {@code exit()} pair up and NEST: a @ReplicaRead method
 *       calling another one must still be "on" after the inner one exits;</li>
 *   <li>after the outermost exit, it is off again and holds no per-thread
 *       leftovers.</li>
 * </ul>
 * Why it matters: a flag that stays on after the method (a missed exit, a
 * reused thread) would silently send a later write-path read to a stale replica —
 * the very bug class this module exists to remove.
 */
public final class ReplicaContext {

    private ReplicaContext() {
    }

    /** The current thread starts (another level of) a replica read. */
    public static void enter() {
        throw new UnsupportedOperationException("TODO(you): ReplicaContext.enter");
    }

    /** The current thread leaves one level; off once the outermost leaves. */
    public static void exit() {
        throw new UnsupportedOperationException("TODO(you): ReplicaContext.exit");
    }

    /** True while the current thread is inside a {@link ReplicaRead} method. */
    public static boolean isOn() {
        throw new UnsupportedOperationException("TODO(you): ReplicaContext.isOn");
    }
}
