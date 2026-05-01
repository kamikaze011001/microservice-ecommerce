package org.aibles.ecommerce.common_dto.exception;

public class ImageTooLargeException extends BaseException {

  public ImageTooLargeException() {
    setStatus(400);
    setCode("org.aibles.business.exception.ImageTooLargeException");
  }
}
