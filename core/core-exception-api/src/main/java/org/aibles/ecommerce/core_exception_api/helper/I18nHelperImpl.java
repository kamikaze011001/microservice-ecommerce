package org.aibles.ecommerce.core_exception_api.helper;

import lombok.extern.slf4j.Slf4j;
import org.springframework.context.MessageSource;

import java.util.Locale;
import java.util.Map;

@Slf4j
public class I18nHelperImpl implements I18nHelper {

  private final MessageSource messageSource;

  public I18nHelperImpl(MessageSource messageSource) {
    this.messageSource = messageSource;
  }

  @Override
  public String translate(String code, Locale locale) {
    log.info("(translate)code : {}, locale : {}", code, locale);
    return getMessage(code, locale);
  }

  @Override
  public String translate(String code, Locale locale, Map<String, String> params) {
    log.info("(translate)code : {}, locale : {}", code, locale, params);
    return getMessage(code, locale, params);
  }

  private String getMessage(String code, Locale locale, Map<String, String> params) {
    log.info("country is " + locale.getCountry());
    String message = getMessage(code, locale);
    if (params != null && !params.isEmpty()) {
      for (Map.Entry<String, String> param : params.entrySet()) {
        log.info("param is: " + param);
        message = message.replace(getMessageByParamKey(param.getKey()), param.getValue());
      }
    }
    return message;
  }

  private String getMessage(String code, Locale locale) {
    try {
      return messageSource.getMessage(code, null, locale);
    } catch (Exception e) {
      return code;
    }
  }

  private String getMessageByParamKey(String key) {
    return "%" + key + "%";
  }
}
