package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class InternalErrorException extends BaseException {

  public InternalErrorException() {
    this("common.internal_error", null);
  }

  public InternalErrorException(String code) {
    this(code, null);
  }

  public InternalErrorException(String code, Map<String, String> params) {
    setStatus(500);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
