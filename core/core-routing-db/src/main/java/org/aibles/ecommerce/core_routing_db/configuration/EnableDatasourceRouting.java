package org.aibles.ecommerce.core_routing_db.configuration;

import org.springframework.context.annotation.Import;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Import({MasterDatasourceConfig.class, SlaveDatasourceConfig.class, JTATransactionConfig.class})
public @interface EnableDatasourceRouting {
}
