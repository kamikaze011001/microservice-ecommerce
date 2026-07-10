package org.aibles.ecommerce.core_exception_api;

import org.junit.jupiter.api.Test;
import org.springframework.context.support.ReloadableResourceBundleMessageSource;

import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class BaseBundleTest {

  @Test
  void base_bundle_resolves_common_codes() {
    var ms = new ReloadableResourceBundleMessageSource();
    ms.setBasename("classpath:messages");
    ms.setDefaultEncoding("UTF-8");
    assertThat(ms.getMessage("common.not_found", null, Locale.ENGLISH))
        .isEqualTo("The requested resource was not found.");
    assertThat(ms.getMessage("common.internal_error", null, Locale.ENGLISH))
        .isEqualTo("Something went wrong on our end. Please try again.");
    assertThat(ms.getMessage("validation.failed", null, Locale.ENGLISH))
        .isEqualTo("One or more fields are invalid.");
  }
}
