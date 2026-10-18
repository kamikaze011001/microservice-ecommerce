package org.aibles.ecommerce.core_replica_routing;

import org.hibernate.resource.jdbc.spi.StatementInspector;

import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Hibernate hands every SQL statement to this inspector just before it runs;
 * what it returns is what is sent to ProxySQL.
 *
 * <p>While {@link ReplicaContext#isOn()}, a plain SELECT is prefixed with
 * {@link #HINT} — ProxySQL's rule matches it at the very start of the query and
 * sends it to the replicas. Everything else is returned unchanged:
 * <ul>
 *   <li>INSERT / UPDATE / DELETE — a write must reach the primary (a replica is
 *       read-only and would refuse it);</li>
 *   <li>{@code SELECT … FOR UPDATE / FOR SHARE / LOCK IN SHARE MODE} — a locking
 *       read starts a write;</li>
 *   <li>a statement already carrying the hint — never twice.</li>
 * </ul>
 * Why a comment and not a separate datasource: the routing stays in ProxySQL,
 * the service keeps one connection pool, and a tagged query is visible as-is in
 * ProxySQL's stats.
 */
public class ReplicaHintInspector implements StatementInspector {

    public static final String HINT = "/* replica */ ";

    private static final Pattern LOCKING_READ =
            Pattern.compile("\\bfor\\s+(update|share)\\b|\\block\\s+in\\s+share\\s+mode\\b");

    @Override
    public String inspect(String sql) {
        if (sql == null || !ReplicaContext.isOn()) {
            return sql;
        }
        String trimmed = sql.stripLeading();
        if (trimmed.startsWith(HINT.strip())) {
            return sql;                                    // already tagged
        }
        if (!trimmed.regionMatches(true, 0, "select", 0, "select".length())) {
            return sql;                                    // not a read
        }
        if (LOCKING_READ.matcher(trimmed.toLowerCase(Locale.ROOT)).find()) {
            return sql;                                    // a write-path read
        }
        return HINT + trimmed;
    }
}
