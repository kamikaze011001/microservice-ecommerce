package org.aibles.ecommerce.inventory_service.configuration;

import jakarta.persistence.EntityManagerFactory;
import org.aibles.ecommerce.core_routing_db.configuration.CommonJPAProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import javax.sql.DataSource;

@Configuration
@EnableJpaRepositories(
        basePackages = "org.aibles.ecommerce.inventory_service.repository.slave",
        entityManagerFactoryRef = "slaveEntityManager")
public class SlaveDatasourceConfiguration {

    @Bean
    public EntityManagerFactory slaveEntityManager(DataSource slaveDatasource) {
        HibernateJpaVendorAdapter vendorAdapter = new HibernateJpaVendorAdapter();
        LocalContainerEntityManagerFactoryBean factory = new LocalContainerEntityManagerFactoryBean();
        factory.setJpaVendorAdapter(vendorAdapter);
        factory.setPackagesToScan("org.aibles.ecommerce.inventory_service.entity");
        factory.setJtaDataSource(slaveDatasource);
        factory.setPersistenceUnitName("inventoryServiceSlave");
        factory.setJpaPropertyMap(CommonJPAProperties.getProperties());
        factory.afterPropertiesSet();
        return factory.getObject();
    }
}
