package org.aibles.ecommerce.core_replica_routing;

/**
 * "Is the current thread inside a {@link ReplicaRead} method?" — the one bit of
 * state the aspect writes and the inspector reads.
 *
 * <ul>
 *   <li>Per thread: a {@link ThreadLocal}, so one request's flag never reaches
 *       another request's thread.</li>
 *   <li>Nests: it holds a depth, not a boolean — a @ReplicaRead method calling
 *       another one is still "on" after the inner one returns.</li>
 *   <li>Leaves nothing behind: at depth 0 the ThreadLocal is removed, because the
 *       servers' threads are pooled and the next request would inherit it.</li>
 * </ul>
 * Why it matters: a flag that stays on after the method would silently send a
 * later write-path read to a stale replica — the bug class this module removes.
 */
public final class ReplicaContext {

    private static final ThreadLocal<Integer> DEPTH = new ThreadLocal<>();

    private ReplicaContext() {
    }

    /** The current thread starts (another level of) a replica read. */
    public static void enter() {
        DEPTH.set(depth() + 1);
    }

    /** The current thread leaves one level; off — and cleared — once the outermost leaves. */
    public static void exit() {
        int depth = depth() - 1;
        if (depth <= 0) {
            DEPTH.remove();   // never negative, never a stale 0 left on a pooled thread
        } else {
            DEPTH.set(depth);
        }
    }

    /** True while the current thread is inside a {@link ReplicaRead} method. */
    public static boolean isOn() {
        return depth() > 0;
    }

    private static int depth() {
        Integer d = DEPTH.get();
        return d == null ? 0 : d;
    }
}
