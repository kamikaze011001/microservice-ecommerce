package org.aibles.ecommerce.core_paypal.configuration;

import org.springframework.context.annotation.Import;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Import({CorePaypalConfiguration.class, PaypalRestTemplateConfiguration.class, PaypalConfiguration.class})
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface EnableCorePaypal {
}
