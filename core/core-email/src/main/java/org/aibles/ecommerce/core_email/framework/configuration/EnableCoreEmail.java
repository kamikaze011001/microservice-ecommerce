package org.aibles.ecommerce.core_email.framework.configuration;

import org.springframework.context.annotation.Import;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Import({
    CoreEmailConfiguration.class,
    AsyncConfiguration.class,
    ThymeleafTemplateConfiguration.class
})
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)

public @interface EnableCoreEmail {
}
