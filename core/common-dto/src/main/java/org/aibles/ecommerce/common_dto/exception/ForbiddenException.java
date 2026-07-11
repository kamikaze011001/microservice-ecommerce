package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class ForbiddenException extends BaseException {

  public ForbiddenException() {
    this("common.forbidden", null);
  }

  public ForbiddenException(String code) {
    this(code, null);
  }

  public ForbiddenException(String code, Map<String, String> params) {
    setStatus(403);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
