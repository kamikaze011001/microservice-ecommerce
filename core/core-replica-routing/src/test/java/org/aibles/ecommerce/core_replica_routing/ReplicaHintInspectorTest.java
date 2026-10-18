package org.aibles.ecommerce.core_replica_routing;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ReplicaHintInspectorTest {

    private final ReplicaHintInspector inspector = new ReplicaHintInspector();

    @AfterEach
    void reset() {
        while (ReplicaContext.isOn()) {
            ReplicaContext.exit();
        }
    }

    @Test
    void offByDefault_everyStatementUnchanged() {
        assertThat(inspector.inspect("select o.id from orders o")).isEqualTo("select o.id from orders o");
        assertThat(inspector.inspect("insert into orders values (1)")).isEqualTo("insert into orders values (1)");
    }

    @Test
    void insideAReplicaRead_aSelectIsTaggedAtTheVeryStart() {
        ReplicaContext.enter();

        assertThat(inspector.inspect("select o.id from orders o")).isEqualTo("/* replica */ select o.id from orders o");
    }

    @Test
    void caseAndLeadingWhitespaceDoNotMatter() {
        ReplicaContext.enter();

        assertThat(inspector.inspect("SELECT 1")).isEqualTo("/* replica */ SELECT 1");
        assertThat(inspector.inspect("  \n select 1")).startsWith("/* replica */ ");
    }

    @Test
    void writesAreNeverTagged() {
        ReplicaContext.enter();

        assertThat(inspector.inspect("insert into t values (1)")).isEqualTo("insert into t values (1)");
        assertThat(inspector.inspect("update t set a=1")).isEqualTo("update t set a=1");
        assertThat(inspector.inspect("delete from t")).isEqualTo("delete from t");
    }

    @Test
    void aLockingReadIsAWritePathRead_neverTagged() {
        ReplicaContext.enter();

        assertThat(inspector.inspect("select * from inventory_product where id=? for update"))
                .isEqualTo("select * from inventory_product where id=? for update");
        assertThat(inspector.inspect("SELECT * FROM t WHERE id=1 FOR UPDATE")).doesNotStartWith("/* replica */");
    }

    @Test
    void neverTaggedTwice() {
        ReplicaContext.enter();

        String once = inspector.inspect("select 1");
        assertThat(inspector.inspect(once)).isEqualTo(once);
    }
}
