package org.aibles.ecommerce.common_dto.exception;

public class OrderAlreadyCanceledException extends BaseException {

  public OrderAlreadyCanceledException() {
    setStatus(409);
    setCode("org.aibles.business.exception.OrderAlreadyCanceledException");
  }
}
