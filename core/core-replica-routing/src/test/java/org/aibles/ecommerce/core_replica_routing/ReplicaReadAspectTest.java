package org.aibles.ecommerce.core_replica_routing;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.orm.jpa.HibernatePropertiesCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.jdbc.datasource.embedded.EmbeddedDatabaseBuilder;
import org.springframework.jdbc.datasource.embedded.EmbeddedDatabaseType;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.annotation.Transactional;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * The aspect inside a real Spring context with a real transaction manager
 * (H2), wired exactly as a service gets it: {@link EnableReplicaRouting}.
 */
@SpringJUnitConfig(ReplicaReadAspectTest.Config.class)
class ReplicaReadAspectTest {

    @Autowired Reads reads;
    @Autowired Callers callers;
    @Autowired RecordingDataSource dataSource;
    @Autowired HibernatePropertiesCustomizer customizer;

    @BeforeEach
    void reset() {
        dataSource.flagAtLastConnection.set(null);
    }

    @Test
    void onInsideTheMethod_offAfterwards() {
        assertThat(reads.flag()).isTrue();
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void offAgainEvenWhenTheMethodThrows() {
        assertThatThrownBy(reads::boom).hasMessage("boom");
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void aMethodWithoutTheAnnotationIsNeverOn() {
        assertThat(reads.plain()).isFalse();
    }

    @Test
    void nested_stillOnAfterTheInnerReturns() {
        assertThat(callers.outerThenInner()).isTrue();
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void theGuard_aReplicaReadInsideAReadWriteTransactionIsRefused() {
        // check-then-write / load-mutate-save: the read decides a write → primary only.
        assertThatThrownBy(callers::replicaReadInsideWriteTransaction)
                .isInstanceOf(IllegalStateException.class);
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void insideAReadOnlyTransaction_allowed() {
        assertThat(callers.replicaReadInsideReadOnlyTransaction()).isTrue();
    }

    @Test
    void theFlagIsAlreadyOnWhenTheMethodsOwnTransactionTakesItsConnection() {
        // @ReplicaRead + @Transactional(readOnly = true) on the SAME method: the aspect
        // must wrap the transaction, or the connection is taken before the flag is on.
        assertThat(reads.flagInOwnReadOnlyTransaction()).isTrue();
        assertThat(dataSource.flagAtLastConnection.get()).isTrue();
    }

    @Test
    void theInspectorIsRegisteredOnHibernate() {
        Map<String, Object> props = new HashMap<>();
        customizer.customize(props);
        assertThat(props.get("hibernate.session_factory.statement_inspector")).isInstanceOf(ReplicaHintInspector.class);
    }

    // ------------------------------------------------------------------ fixtures

    static class Reads {
        @ReplicaRead
        public boolean flag() {
            return ReplicaContext.isOn();
        }

        @ReplicaRead
        public void boom() {
            throw new RuntimeException("boom");
        }

        public boolean plain() {
            return ReplicaContext.isOn();
        }

        @ReplicaRead
        @Transactional(readOnly = true)
        public boolean flagInOwnReadOnlyTransaction() {
            return ReplicaContext.isOn();
        }
    }

    static class Callers {
        private final Reads reads;

        Callers(Reads reads) {
            this.reads = reads;
        }

        @ReplicaRead
        public boolean outerThenInner() {
            reads.flag();
            return ReplicaContext.isOn();
        }

        @Transactional
        public void replicaReadInsideWriteTransaction() {
            reads.flag();
        }

        @Transactional(readOnly = true)
        public boolean replicaReadInsideReadOnlyTransaction() {
            return reads.flag();
        }
    }

    /** Records whether the replica flag was on at the moment a connection was taken. */
    static class RecordingDataSource extends DelegatingDataSource {
        final AtomicReference<Boolean> flagAtLastConnection = new AtomicReference<>();

        RecordingDataSource(DataSource target) {
            super(target);
        }

        @Override
        public Connection getConnection() throws SQLException {
            flagAtLastConnection.set(ReplicaContext.isOn());
            return super.getConnection();
        }
    }

    @Configuration
    @EnableReplicaRouting
    @EnableTransactionManagement
    static class Config {
        @Bean
        RecordingDataSource dataSource() {
            return new RecordingDataSource(new EmbeddedDatabaseBuilder().setType(EmbeddedDatabaseType.H2).generateUniqueName(true).build());
        }

        @Bean
        PlatformTransactionManager transactionManager(RecordingDataSource ds) {
            return new DataSourceTransactionManager(ds);
        }

        @Bean
        Reads reads() {
            return new Reads();
        }

        @Bean
        Callers callers(Reads reads) {
            return new Callers(reads);
        }
    }
}
