package org.aibles.ecommerce.core_replica_routing;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * This read may be served by a MySQL <b>replica</b> — seconds stale is fine.
 *
 * <p>Every read goes to the primary unless its method carries this annotation
 * (ADR 0012). Put it on a method only when ALL of these hold:
 * <ol>
 *   <li>its result never decides a write (no check-then-write);</li>
 *   <li>it doesn't load a row to modify and save it;</li>
 *   <li>the user won't miss their own change from a moment ago (no read-after-write);</li>
 *   <li>it isn't money, stock or security.</li>
 * </ol>
 * Unsure? Leave it off — the primary is always correct.
 *
 * <p>How it works: while the method runs, every SELECT is prefixed with the
 * comment {@code /* replica *}{@code /}, and ProxySQL routes those to the
 * replica hostgroup. Calling it inside a read-write transaction throws — that
 * is exactly the check-then-write case.
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface ReplicaRead {
}
