package org.aibles.ecommerce.core_exception_api.configuration;

import jakarta.validation.ConstraintViolation;
import jakarta.validation.ConstraintViolationException;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.common_dto.exception.BaseException;
import org.aibles.ecommerce.common_dto.response.BaseResponse;
import org.aibles.ecommerce.core_exception_api.helper.I18nHelper;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.context.request.WebRequest;

import java.util.HashMap;
import java.util.Map;

@Slf4j
@RequiredArgsConstructor
@RestControllerAdvice
public class GlobalExceptionHandler {

  private final I18nHelper i18nHelper;

  @ExceptionHandler(BaseException.class)
  public ResponseEntity<BaseResponse> handleBaseException(BaseException ex, WebRequest webRequest) {
    log.info("(handleBaseException)ex: {}, locale: {}", ex.getCode(), webRequest.getLocale());
    String message = i18nHelper.translate(ex.getCode(), webRequest.getLocale(), ex.getParams());
    Map<String, Object> messageMap = new HashMap<>();
    messageMap.put("message", message);
    HttpStatus status = HttpStatus.valueOf(ex.getStatus());
    BaseResponse baseResponse = BaseResponse.from(ex.getStatus(), status.getReasonPhrase(), messageMap);
    return new ResponseEntity<>(baseResponse, status);
  }

  @ExceptionHandler(MethodArgumentNotValidException.class)
  public ResponseEntity<BaseResponse> handleValidationExceptions(MethodArgumentNotValidException exception) {
    log.info("(handleValidationExceptions)exception: {}", exception.getMessage());
    Map<String, String> errors = new HashMap<>();
    exception.getBindingResult().getAllErrors().forEach(error -> {
      String fieldName = ((FieldError) error).getField();
      String errorMessage = error.getDefaultMessage();
      errors.put(fieldName, errorMessage);
    });
    log.info("(handleValidationExceptions) {}", errors);
    BaseResponse errorResponse = BaseResponse.badRequest(errors);
    return new ResponseEntity<>(errorResponse, HttpStatus.BAD_REQUEST);
  }

  @ExceptionHandler(ConstraintViolationException.class)
  public ResponseEntity<BaseResponse> handleConstraintViolationException(ConstraintViolationException exception) {
    log.info("(handleConstraintViolationException)exception: {}", exception.getMessage());
    Map<String, String> errors = new HashMap<>();
    for (ConstraintViolation<?> constraintViolation : exception.getConstraintViolations()) {
      String fieldName = constraintViolation.getPropertyPath().toString();
      String errorMessage = constraintViolation.getMessage();
      errors.put(fieldName, errorMessage);
    }
    BaseResponse errorResponse = BaseResponse.badRequest(errors);
    return new ResponseEntity<>(errorResponse, HttpStatus.BAD_REQUEST);
  }
}
