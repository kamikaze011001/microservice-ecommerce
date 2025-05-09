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
        return dataSourceBean;
    }


}
