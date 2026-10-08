package org.aibles.ecommerce.core_mongo_event.configuration;

import org.aibles.ecommerce.core_mongo_event.listener.MongoSavedEventListener;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.mongodb.core.MongoTemplate;

@Configuration
public class MongoEventConfiguration {

    @Bean
    public MongoSavedEventListener mongoSavedEventListener(MongoTemplate mongoTemplate) {
        return new MongoSavedEventListener(mongoTemplate);
    }
}
