package org.aibles.ecommerce.core_routing_db.configuration;

import com.atomikos.jdbc.AtomikosDataSourceBean;
import com.mysql.cj.jdbc.MysqlXADataSource;
import org.springframework.boot.autoconfigure.jdbc.DataSourceProperties;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;
import java.sql.SQLException;

@Configuration
public class MasterDatasourceConfig {

    @ConfigurationProperties("spring.datasource.master")
    @Bean
    public DataSourceProperties masterDataSourceProperties() {
        return new DataSourceProperties();
    }

    @Bean
    public DataSource masterDatasource(DataSourceProperties masterDataSourceProperties) throws SQLException {
        MysqlXADataSource mysqlXaDataSource = new MysqlXADataSource();
        mysqlXaDataSource.setUrl(masterDataSourceProperties.getUrl());
        mysqlXaDataSource.setUser(masterDataSourceProperties.getUsername());
        mysqlXaDataSource.setPassword(masterDataSourceProperties.getPassword());
        mysqlXaDataSource.setPinGlobalTxToPhysicalConnection(true);
        AtomikosDataSourceBean dataSourceBean = new AtomikosDataSourceBean();
        dataSourceBean.setUniqueResourceName("master");
        dataSourceBean.setXaDataSource(mysqlXaDataSource);
        // Atomikos defaults maxPoolSize to 1, which serializes every concurrent
        // transaction on this datasource and exhausts under load (a 50-VU login
        // burst -> "Connection pool exhausted"). 20 absorbs the burst while
        // staying under MySQL max_connections=151 (~6 master-side replicas x 20 =
        // 120); min 5 keeps connections warm to avoid XA cold-start on a burst.
        dataSourceBean.setMinPoolSize(5);
        dataSourceBean.setMaxPoolSize(20);
        return dataSourceBean;
    }


}
