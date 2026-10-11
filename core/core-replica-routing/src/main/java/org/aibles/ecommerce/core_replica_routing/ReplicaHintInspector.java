package org.aibles.ecommerce.core_replica_routing;

import org.hibernate.resource.jdbc.spi.StatementInspector;

/**
 * Hibernate hands every SQL statement to this inspector just before it runs;
 * what it returns is what is sent to ProxySQL.
 *
 * <p>TODO(you) — behaviour the tests pin (ReplicaHintInspectorTest):
 * <ul>
 *   <li>while {@link ReplicaContext#isOn()}: a plain SELECT comes back prefixed
 *       with exactly {@code /* replica *}{@code /} and a space — ProxySQL's rule
 *       matches that at the very start of the query;</li>
 *   <li>never tag anything else: INSERT / UPDATE / DELETE, and a
 *       {@code SELECT … FOR UPDATE} (a locking read is a write-path read);</li>
 *   <li>case and leading whitespace in the SQL don't matter;</li>
 *   <li>never tag twice;</li>
 *   <li>when the context is off, every statement comes back unchanged.</li>
 * </ul>
 * Why a comment and not a separate datasource: the routing stays in ProxySQL,
 * the service keeps one connection pool, and a tagged query is visible as-is in
 * ProxySQL's stats.
 */
public class ReplicaHintInspector implements StatementInspector {

    public static final String HINT = "/* replica */ ";

    @Override
    public String inspect(String sql) {
        throw new UnsupportedOperationException("TODO(you): ReplicaHintInspector.inspect");
    }
}
