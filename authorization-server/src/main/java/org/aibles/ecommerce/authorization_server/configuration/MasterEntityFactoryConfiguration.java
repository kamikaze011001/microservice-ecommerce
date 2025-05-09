package org.aibles.ecommerce.authorization_server.configuration;

import jakarta.persistence.EntityManagerFactory;
import org.aibles.ecommerce.core_routing_db.configuration.CommonJPAProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import javax.sql.DataSource;
import java.util.Map;

@Configuration
@EnableJpaRepositories(
        basePackages = "org.aibles.ecommerce.authorization_server.repository.master",
        entityManagerFactoryRef = "masterEntityManager")
public class MasterEntityFactoryConfiguration {

    @Bean
    public EntityManagerFactory masterEntityManager(DataSource masterDatasource) {
        HibernateJpaVendorAdapter vendorAdapter = new HibernateJpaVendorAdapter();
        LocalContainerEntityManagerFactoryBean factory = new LocalContainerEntityManagerFactoryBean();
        factory.setJpaVendorAdapter(vendorAdapter);
        factory.setPackagesToScan("org.aibles.ecommerce.authorization_server.entity");
        factory.setJtaDataSource(masterDatasource);
        factory.setPersistenceUnitName("authorizationServerMaster");
        Map<String, String> jpaProperties = CommonJPAProperties.getProperties();
        jpaProperties.put("hibernate.hbm2ddl.auto", "update");
        factory.setJpaPropertyMap(jpaProperties);
        factory.afterPropertiesSet();
        return factory.getObject();
    }
}
