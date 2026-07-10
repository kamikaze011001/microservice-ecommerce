package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class BadRequestException extends BaseException {

  public BadRequestException() {
    this("common.bad_request", null);
  }

  public BadRequestException(String code) {
    this(code, null);
  }

  public BadRequestException(String code, Map<String, String> params) {
    setStatus(400);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
