package org.aibles.ecommerce.core_email.framework.repository.datasource;


import jakarta.mail.Message;
import jakarta.mail.internet.InternetAddress;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_email.adapter.repository.EmailHelper;
import org.aibles.ecommerce.core_email.business.email.BaseEmail;
import org.springframework.core.io.FileSystemResource;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.scheduling.annotation.Async;
import org.thymeleaf.context.Context;
import org.thymeleaf.spring6.SpringTemplateEngine;

import java.util.Map;
import java.util.Objects;

@Slf4j
public class EmailHelperImpl implements EmailHelper {
  private JavaMailSender emailSender;
  private SpringTemplateEngine templateEngine;
  // From address for every outbound mail. Wired to the authenticated SMTP
  // account (spring.mail.username). Without it JavaMail defaults From to
  // root@<pod-hostname> — a non-existent domain — and Gmail (which also requires
  // the From to match the authenticated user) silently drops it or files it as
  // spam, so OTPs "send" (250 OK) but never reach the inbox.
  private String from;

  public EmailHelperImpl(JavaMailSender emailSender, SpringTemplateEngine templateEngine, String from) {
    this.emailSender = emailSender;
    this.templateEngine = templateEngine;
    this.from = from;
  }

  @Async
  @Override
  public void send(String subject, String to, String content) {
    try {
      var message = new SimpleMailMessage();
      message.setFrom(from);
      message.setTo(to);
      message.setSubject(subject);
      message.setText(content);
      emailSender.send(message);
    } catch (Exception ex) {
      log.error("(send)to: {}, subject: {}, ex: {}", to, subject, ex.getMessage());
    }
  }

  @Async
  @Override
  public void send(String subject, String to, String template, Map<String, Object> properties) {
    try {
      var message = emailSender.createMimeMessage();
      message.setFrom(new InternetAddress(from));
      message.setRecipients(Message.RecipientType.TO, to);
      message.setSubject(subject);
      message.setContent(getContent(template, properties), BaseEmail.CONTENT_TYPE_TEXT_HTML);
      emailSender.send(message);
    } catch (Exception ex) {
      log.info("(send)subject: {}, to: {}, ex: {} ", subject, to, ex.getMessage());
    }
  }

  @Override
  public void send(String subject, String to, String content, String fileToAttach) {
    try {
      var message = emailSender.createMimeMessage();
      var helper = new MimeMessageHelper(message, true);
      helper.setFrom(from);
      helper.setTo(to);
      helper.setSubject(subject);
      helper.setText(content);
      FileSystemResource fileSystemResource = new FileSystemResource(fileToAttach);
      helper.addAttachment(Objects.requireNonNull(fileSystemResource.getFilename()), fileSystemResource);
      emailSender.send(message);
    } catch (Exception ex) {
      log.info("(send)subject: {}, to: {}, ex: {} ", subject, to, ex.getMessage());
    }

  }

  private String getContent(String template, Map<String, Object> properties) {
    var context = new Context();
    context.setVariables(properties);
    return templateEngine.process(template, context);
  }
}



