package org.aibles.ecommerce.core_mongo_event.listener;

import org.aibles.ecommerce.common_dto.event.MongoSavedEvent;
import org.aibles.ecommerce.core_mongo_event.entity.Event;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.scheduling.annotation.Async;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

import java.lang.reflect.Method;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

@ExtendWith(MockitoExtension.class)
class MongoSavedEventListenerTest {

    @Mock MongoTemplate mongoTemplate;

    @Test
    void handle_insertsEventWithNameAggregateIdAndData() {
        MongoSavedEventListener listener = new MongoSavedEventListener(mongoTemplate);
        Object data = Map.of("orderId", "order-1");

        listener.handle(new MongoSavedEvent(this, "Order.Created", "order-1", data));

        ArgumentCaptor<Event> saved = ArgumentCaptor.forClass(Event.class);
        verify(mongoTemplate).insert(saved.capture());
        assertThat(saved.getValue().getName()).isEqualTo("Order.Created");
        assertThat(saved.getValue().getAggregateId()).isEqualTo("order-1");
        assertThat(saved.getValue().getData()).isEqualTo(data.toString());
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"  "})
    void handle_blankAggregateId_throwsAndInsertsNothing(String aggregateId) {
        MongoSavedEventListener listener = new MongoSavedEventListener(mongoTemplate);

        assertThatThrownBy(() -> listener.handle(
                new MongoSavedEvent(this, "Payment.Canceled", aggregateId, Map.of())))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("Payment.Canceled");
        verify(mongoTemplate, never()).insert(any(Event.class));
    }

    @Test
    void handle_runsAfterCommit_evenWithoutTransaction_andSynchronously() throws NoSuchMethodException {
        Method handle = MongoSavedEventListener.class.getMethod("handle", MongoSavedEvent.class);

        TransactionalEventListener tx = handle.getAnnotation(TransactionalEventListener.class);
        assertThat(tx).as("must be a @TransactionalEventListener").isNotNull();
        assertThat(tx.phase()).isEqualTo(TransactionPhase.AFTER_COMMIT);
        assertThat(tx.fallbackExecution())
                .as("publishers without a transaction (product-service) must not be dropped")
                .isTrue();
        assertThat(handle.getAnnotation(Async.class))
                .as("@Async lets writes reorder before Kafka ever sees them")
                .isNull();
    }
}
