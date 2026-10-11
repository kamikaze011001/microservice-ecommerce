package org.aibles.ecommerce.core_replica_routing;

import org.springframework.context.annotation.Import;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Turns {@link ReplicaRead} on for a service: put it on the application class,
 * next to the single datasource that points at ProxySQL.
 */
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Import(ReplicaRoutingConfiguration.class)
public @interface EnableReplicaRouting {
}
