package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class NotFoundException extends BaseException {

  public NotFoundException() {
    this("common.not_found", null);
  }

  public NotFoundException(String code) {
    this(code, null);
  }

  public NotFoundException(String code, Map<String, String> params) {
    setStatus(404);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
