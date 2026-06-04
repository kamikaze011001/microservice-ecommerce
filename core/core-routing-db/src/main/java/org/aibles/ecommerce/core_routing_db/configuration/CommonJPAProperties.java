package org.aibles.ecommerce.core_routing_db.configuration;

import java.util.HashMap;
import java.util.Map;

public class CommonJPAProperties {


    private CommonJPAProperties() {}

    public static Map<String, String> getProperties() {
        Map<String, String> props = new HashMap<>();
        props.put("hibernate.physical_naming_strategy", "org.hibernate.boot.model.naming.CamelCaseToUnderscoresNamingStrategy");
        props.put("hibernate.implicit_naming_strategy", "org.springframework.boot.orm.jpa.hibernate.SpringImplicitNamingStrategy");
        props.put("hibernate.dialect", "org.hibernate.dialect.MySQLDialect");
        return props;
    }

    /**
     * Properties for a SLAVE (read) EntityManagerFactory. Adds a query-only
     * interceptor so the slave session never emits an UPDATE — preventing the
     * master/slave dual-flush that self-deadlocks when both datasources point at
     * one MySQL. Use this for every {@code slaveEntityManager}; keep
     * {@link #getProperties()} for the master EMF (it must still write).
     */
    public static Map<String, String> getSlaveProperties() {
        Map<String, String> props = getProperties();
        props.put("hibernate.session_factory.interceptor", ReadOnlySlaveInterceptor.class.getName());
        return props;
    }
}
