package org.aibles.ecommerce.product_service;

import org.junit.jupiter.api.Test;
import org.springframework.context.support.ReloadableResourceBundleMessageSource;

import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class ProductErrorCatalogTest {

  private ReloadableResourceBundleMessageSource bundle() {
    var ms = new ReloadableResourceBundleMessageSource();
    ms.setBasenames("classpath:messages", "classpath:messages/product");
    ms.setDefaultEncoding("UTF-8");
    return ms;
  }

  @Test
  void product_bundle_resolves_its_own_code() {
    assertThat(bundle().getMessage("product.not_found", new Object[]{}, Locale.ENGLISH))
        .contains("Product");
  }

  @Test
  void base_bundle_resolves_shared_image_codes() {
    var ms = bundle();
    assertThat(ms.getMessage("common.image.key_forbidden", null, Locale.ENGLISH)).isNotBlank();
    assertThat(ms.getMessage("common.image.not_uploaded", null, Locale.ENGLISH)).isNotBlank();
    assertThat(ms.getMessage("common.image.type_not_allowed", null, Locale.ENGLISH)).isNotBlank();
    assertThat(ms.getMessage("common.image.too_large", null, Locale.ENGLISH)).isNotBlank();
  }
}
