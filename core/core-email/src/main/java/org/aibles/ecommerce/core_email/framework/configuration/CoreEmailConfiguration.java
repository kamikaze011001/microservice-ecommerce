package org.aibles.ecommerce.core_email.framework.configuration;

import org.aibles.ecommerce.core_email.adapter.repository.EmailHelper;
import org.aibles.ecommerce.core_email.framework.repository.datasource.EmailHelperImpl;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.mail.javamail.JavaMailSender;
import org.thymeleaf.spring6.SpringTemplateEngine;

@Configuration
public class CoreEmailConfiguration {

  // From address for outbound mail = the authenticated SMTP account. Gmail
  // rewrites/spam-filters a From that doesn't match the authenticated user.
  @Bean
  public EmailHelper emailService(
      JavaMailSender emailSender,
      SpringTemplateEngine templateEngine,
      @Value("${spring.mail.username}") String from) {
    return new EmailHelperImpl(emailSender, templateEngine, from);
  }

}
