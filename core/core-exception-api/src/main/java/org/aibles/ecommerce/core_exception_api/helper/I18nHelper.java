package org.aibles.ecommerce.core_exception_api.helper;

import java.util.Locale;
import java.util.Map;

public interface I18nHelper {
  String translate(String code, Locale locale);

  String translate(String code, Locale locale, Map<String, String> params);
}
