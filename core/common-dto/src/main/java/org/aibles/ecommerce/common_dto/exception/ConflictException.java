package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class ConflictException extends BaseException {

  public ConflictException() {
    this("common.conflict", null);
  }

  public ConflictException(String code) {
    this(code, null);
  }

  public ConflictException(String code, Map<String, String> params) {
    setStatus(409);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
