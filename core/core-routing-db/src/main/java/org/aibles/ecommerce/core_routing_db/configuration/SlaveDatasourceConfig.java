package org.aibles.ecommerce.core_routing_db.configuration;

import com.atomikos.jdbc.AtomikosDataSourceBean;
import com.mysql.cj.jdbc.MysqlXADataSource;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.autoconfigure.jdbc.DataSourceProperties;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Configuration
public class SlaveDatasourceConfig {

    @ConfigurationProperties("spring.datasource.slave1")
    @Bean
    public DataSourceProperties slave1DataSourceProperties() {
        return new DataSourceProperties();
    }

    @ConfigurationProperties("spring.datasource.slave2")
    @Bean
    public DataSourceProperties slave2DataSourceProperties() {
        return new DataSourceProperties();
    }

    @Bean
    public DataSource slave1Datasource(DataSourceProperties slave1DataSourceProperties) throws SQLException {
        MysqlXADataSource mysqlXaDataSource = new MysqlXADataSource();
        mysqlXaDataSource.setUrl(slave1DataSourceProperties.getUrl());
        mysqlXaDataSource.setUser(slave1DataSourceProperties.getUsername());
        mysqlXaDataSource.setPassword(slave1DataSourceProperties.getPassword());
        mysqlXaDataSource.setPinGlobalTxToPhysicalConnection(true);
        AtomikosDataSourceBean dataSourceBean = new AtomikosDataSourceBean();
        dataSourceBean.setUniqueResourceName("slave1");
        dataSourceBean.setXaDataSource(mysqlXaDataSource);
        return dataSourceBean;
    }

    @Bean
    public DataSource slave2Datasource(DataSourceProperties slave2DataSourceProperties) throws SQLException {
        MysqlXADataSource mysqlXaDataSource = new MysqlXADataSource();
        mysqlXaDataSource.setUrl(slave2DataSourceProperties.getUrl());
        mysqlXaDataSource.setUser(slave2DataSourceProperties.getUsername());
        mysqlXaDataSource.setPassword(slave2DataSourceProperties.getPassword());
        mysqlXaDataSource.setPinGlobalTxToPhysicalConnection(true);
        AtomikosDataSourceBean dataSourceBean = new AtomikosDataSourceBean();
        dataSourceBean.setUniqueResourceName("slave2");
        dataSourceBean.setXaDataSource(mysqlXaDataSource);
        return dataSourceBean;
    }

    @Bean
    public DataSource slaveDatasource(
            @Qualifier("slave1Datasource") DataSource slave1Datasource,
            @Qualifier("slave2Datasource") DataSource slave2Datasource
    ) {
        Map<Object, Object> dataSources = new HashMap<>();
        dataSources.put("slave1", slave1Datasource);
        dataSources.put("slave2", slave2Datasource);
        SlaveDatasourceRouting slaveDatasourceRouting = new SlaveDatasourceRouting(
            List.of("slave1", "slave2")
        );
        slaveDatasourceRouting.setTargetDataSources(dataSources);
        slaveDatasourceRouting.setDefaultTargetDataSource(slave1Datasource);
        return slaveDatasourceRouting;
    }
}
