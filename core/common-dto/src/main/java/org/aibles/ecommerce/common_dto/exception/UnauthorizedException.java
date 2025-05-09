package org.aibles.ecommerce.common_dto.exception;

public class UnauthorizedException extends BaseException {
  public UnauthorizedException() {
    setStatus(401);
    setCode("org.aibles.business.exception.UnauthorizedException");
  }
}
