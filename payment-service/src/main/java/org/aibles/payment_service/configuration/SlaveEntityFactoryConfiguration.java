package org.aibles.payment_service.configuration;

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
        basePackages = "org.aibles.payment_service.repository.slave",
        entityManagerFactoryRef = "slaveEntityManager")
public class SlaveEntityFactoryConfiguration {

    @Bean
    public EntityManagerFactory slaveEntityManager(DataSource slaveDatasource) {
        HibernateJpaVendorAdapter vendorAdapter = new HibernateJpaVendorAdapter();
        LocalContainerEntityManagerFactoryBean factory = new LocalContainerEntityManagerFactoryBean();
        factory.setJpaVendorAdapter(vendorAdapter);
        factory.setPackagesToScan("org.aibles.payment_service.entity");
        factory.setJtaDataSource(slaveDatasource);
        factory.setPersistenceUnitName("paymentServiceSlave");
        factory.setJpaPropertyMap(CommonJPAProperties.getProperties());
        factory.afterPropertiesSet();
        return factory.getObject();
    }
}
