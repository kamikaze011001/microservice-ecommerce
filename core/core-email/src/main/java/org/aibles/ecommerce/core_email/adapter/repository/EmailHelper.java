package org.aibles.ecommerce.core_email.adapter.repository;

import java.util.Map;

public interface EmailHelper {
  /**
   * Send email with text
   *
   * @param subject - the subject of the email
   * @param to      - the email address of the receiver
   * @param content - the body of the email
   */
  void send(String subject, String to, String content);

  /**
   * Send mail with html
   *
   * @param subject    - the subject of the email
   * @param to         - the email address of the receiver
   * @param template   - the file name html template of the email
   * @param properties - the properties of the html template
   */
  void send(String subject, String to, String template, Map<String, Object> properties);

  /**
   * Send mail file attach
   *
   * @param subject      - the subject of the email
   * @param to           - the email address of the receiver
   * @param content      - the body of the mail
   * @param fileToAttach - the path of the file need to attach
   */
  void send(String subject, String to, String content, String fileToAttach);
}
