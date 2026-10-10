package org.aibles.ecommerce.orchestrator_service.listener;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.aibles.ecommerce.orchestrator_service.entity.SagaItem;

import java.util.List;

/** Test access to MongoEventListener's package-private parsing. */
public final class MongoEventListenerProbe {

    private MongoEventListenerProbe() {
    }

    public static List<SagaItem> extractItems(ObjectMapper mapper, Object data) {
        return new MongoEventListener(mapper, null, null).extractItems(data);
    }
}
