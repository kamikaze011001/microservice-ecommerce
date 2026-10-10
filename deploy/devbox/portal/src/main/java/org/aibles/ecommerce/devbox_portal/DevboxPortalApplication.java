package org.aibles.ecommerce.devbox_portal;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class DevboxPortalApplication {

    public static void main(String[] args) {
        SpringApplication.run(DevboxPortalApplication.class, args);
    }
}
