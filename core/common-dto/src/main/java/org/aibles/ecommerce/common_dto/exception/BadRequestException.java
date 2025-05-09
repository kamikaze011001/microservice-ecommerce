package org.aibles.ecommerce.common_dto.exception;

public class BadRequestException extends BaseException {
  public BadRequestException() {
    setStatus(400);
    setCode("org.aibles.business.exception.BadRequestException");
  }
}
