package org.aibles.ecommerce.common_dto.exception;

public class ImageTypeNotAllowedException extends BaseException {

  public ImageTypeNotAllowedException() {
    setStatus(400);
    setCode("org.aibles.business.exception.ImageTypeNotAllowedException");
  }
}
