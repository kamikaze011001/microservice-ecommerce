package org.aibles.ecommerce.core_replica_routing;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CompletableFuture;

import static org.assertj.core.api.Assertions.assertThat;

class ReplicaContextTest {

    @AfterEach
    void reset() {
        while (ReplicaContext.isOn()) {
            ReplicaContext.exit();
        }
    }

    @Test
    void offByDefault() {
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void onBetweenEnterAndExit() {
        ReplicaContext.enter();
        assertThat(ReplicaContext.isOn()).isTrue();

        ReplicaContext.exit();
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void nests_theInnerExitDoesNotTurnTheOuterOff() {
        ReplicaContext.enter();      // outer @ReplicaRead
        ReplicaContext.enter();      // inner @ReplicaRead it calls
        ReplicaContext.exit();       // inner returns

        assertThat(ReplicaContext.isOn()).isTrue();

        ReplicaContext.exit();       // outer returns
        assertThat(ReplicaContext.isOn()).isFalse();
    }

    @Test
    void perThread_anotherThreadNeverSeesIt() throws Exception {
        ReplicaContext.enter();

        boolean seenElsewhere = CompletableFuture.supplyAsync(ReplicaContext::isOn).get();

        assertThat(seenElsewhere).isFalse();
        assertThat(ReplicaContext.isOn()).isTrue();
    }
}
