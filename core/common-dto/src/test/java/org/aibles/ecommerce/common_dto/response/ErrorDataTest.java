package org.aibles.ecommerce.common_dto.response;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ErrorDataTest {

  private final ObjectMapper mapper = new ObjectMapper();

  @Test
  void serializes_code_and_message_and_omits_null_errors() throws Exception {
    String json = mapper.writeValueAsString(ErrorData.of("order.not_found", "Order A123 was not found."));
    assertThat(json).contains("\"code\":\"order.not_found\"");
    assertThat(json).contains("\"message\":\"Order A123 was not found.\"");
    assertThat(json).doesNotContain("errors");
  }

  @Test
  void serializes_field_errors_map() throws Exception {
    String json = mapper.writeValueAsString(
        ErrorData.of("validation.failed", "One or more fields are invalid.", Map.of("email", "must be valid")));
    assertThat(json).contains("\"errors\":{\"email\":\"must be valid\"}");
  }
}
