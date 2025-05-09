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
}
