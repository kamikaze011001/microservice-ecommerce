package org.aibles.ecommerce.core_exception_api;

import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.common_dto.response.ErrorData;
import org.aibles.ecommerce.core_exception_api.configuration.GlobalExceptionHandler;
import org.aibles.ecommerce.core_exception_api.helper.I18nHelper;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;
import org.springframework.web.context.request.WebRequest;

import java.util.Locale;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class GlobalExceptionHandlerTest {

  @Test
  void baseException_puts_code_and_message_inside_errorData() {
    I18nHelper i18n = mock(I18nHelper.class);
    when(i18n.translate(eq("order.not_found"), any(), any())).thenReturn("Order A123 was not found.");
    WebRequest req = mock(WebRequest.class);
    when(req.getLocale()).thenReturn(Locale.ENGLISH);

    GlobalExceptionHandler handler = new GlobalExceptionHandler(i18n);
    NotFoundException ex = new NotFoundException("order.not_found", Map.of("id", "A123"));

    ResponseEntity<BaseResponse> resp = handler.handleBaseException(ex, req);

    assertThat(resp.getStatusCode().value()).isEqualTo(404);
    ErrorData data = (ErrorData) resp.getBody().getData();
    assertThat(data.getCode()).isEqualTo("order.not_found");
    assertThat(data.getMessage()).isEqualTo("Order A123 was not found.");
    assertThat(data.getErrors()).isNull();
  }
}
