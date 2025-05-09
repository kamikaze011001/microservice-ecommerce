package org.aibles.ecommerce.common_dto.exception;

public class InternalErrorException extends BaseException {
  public InternalErrorException() {
    setStatus(500);
    setCode("org.aibles.business.exception.InternalErrorException");
  }
}
