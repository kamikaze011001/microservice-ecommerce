package org.aibles.ecommerce.common_dto.exception;

public class NotFoundException extends BaseException {
  public NotFoundException() {
    setStatus(404);
    setCode("org.aibles.business.exception.NotFoundException");
  }
}
