package org.aibles.ecommerce.common_dto.exception;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CommonExceptionCodeTest {

  @Test
  void notFound_has_dotted_default_code_and_404() {
    NotFoundException ex = new NotFoundException();
    assertThat(ex.getStatus()).isEqualTo(404);
    assertThat(ex.getCode()).isEqualTo("common.not_found");
  }

  @Test
  void notFound_accepts_specific_code_and_params() {
    NotFoundException ex = new NotFoundException("order.not_found", Map.of("id", "A123"));
    assertThat(ex.getCode()).isEqualTo("order.not_found");
    assertThat(ex.getParams()).containsEntry("id", "A123");
    assertThat(ex.getStatus()).isEqualTo(404);
  }
}
