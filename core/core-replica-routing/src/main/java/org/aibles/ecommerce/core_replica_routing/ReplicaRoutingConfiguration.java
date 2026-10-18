package org.aibles.ecommerce.core_replica_routing;

import org.springframework.boot.autoconfigure.orm.jpa.HibernatePropertiesCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.EnableAspectJAutoProxy;

/**
 * Wiring only — the logic lives in {@link ReplicaContext},
 * {@link ReplicaReadAspect} and {@link ReplicaHintInspector}.
 */
@Configuration(proxyBeanMethods = false)
@EnableAspectJAutoProxy
public class ReplicaRoutingConfiguration {

    @Bean
    public ReplicaReadAspect replicaReadAspect() {
        return new ReplicaReadAspect();
    }

    /** Registers the inspector on the service's (single) EntityManagerFactory. */
    @Bean
    public HibernatePropertiesCustomizer replicaHintInspectorCustomizer() {
        return props -> props.put("hibernate.session_factory.statement_inspector", new ReplicaHintInspector());
    }
}
