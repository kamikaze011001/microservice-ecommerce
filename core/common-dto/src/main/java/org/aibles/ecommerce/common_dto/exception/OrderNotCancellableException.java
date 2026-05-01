package org.aibles.ecommerce.common_dto.exception;

public class OrderNotCancellableException extends BaseException {

  public OrderNotCancellableException() {
    setStatus(409);
    setCode("org.aibles.business.exception.OrderNotCancellableException");
  }
}
