package org.aibles.ecommerce.common_dto.exception;

public class ForbiddenException extends BaseException {

  public ForbiddenException() {
    setStatus(403);
    setCode("org.aibles.business.exception.ForbiddenException");
  }
}
