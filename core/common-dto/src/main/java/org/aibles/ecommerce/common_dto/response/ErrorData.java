package org.aibles.ecommerce.common_dto.response;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.Map;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonInclude(JsonInclude.Include.NON_NULL)
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ErrorData {

  private String code;
  private String message;
  private Map<String, String> errors;

  public static ErrorData of(String code, String message) {
    return new ErrorData(code, message, null);
  }

  public static ErrorData of(String code, String message, Map<String, String> errors) {
    return new ErrorData(code, message, errors);
  }
}
