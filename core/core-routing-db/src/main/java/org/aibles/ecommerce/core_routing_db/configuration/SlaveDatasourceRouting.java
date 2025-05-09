package org.aibles.ecommerce.core_routing_db.configuration;

import org.springframework.jdbc.datasource.lookup.AbstractRoutingDataSource;

import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

public class SlaveDatasourceRouting extends AbstractRoutingDataSource {

    private final List<String> slaveDbKey;

    private final AtomicInteger counter = new AtomicInteger(0);

    public SlaveDatasourceRouting(List<String> slaveDbKey) {
        this.slaveDbKey = slaveDbKey;
    }

    @Override
    protected Object determineCurrentLookupKey() {
        int index = counter.getAndAccumulate(slaveDbKey.size(), (current, size) -> (current + 1) % size);
        return slaveDbKey.get(index);
    }
}
