package org.aibles.ecommerce.common_dto.exception;

import java.util.Map;

public class UnauthorizedException extends BaseException {

  public UnauthorizedException() {
    this("common.unauthorized", null);
  }

  public UnauthorizedException(String code) {
    this(code, null);
  }

  public UnauthorizedException(String code, Map<String, String> params) {
    setStatus(401);
    setCode(code);
    if (params != null) {
      params.forEach(this::addParams);
    }
  }
}
