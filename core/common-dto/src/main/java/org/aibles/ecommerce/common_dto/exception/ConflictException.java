package org.aibles.ecommerce.common_dto.exception;


public class ConflictException extends BaseException {
  public ConflictException() {
    setStatus(409);
    setCode("org.aibles.business.exception.ConflictException");
  }
}
