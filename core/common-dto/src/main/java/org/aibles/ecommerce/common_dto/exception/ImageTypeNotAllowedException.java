package org.aibles.ecommerce.common_dto.exception;

public class ImageTypeNotAllowedException extends BaseException {

  public ImageTypeNotAllowedException() {
    setStatus(400);
    setCode("common.image.type_not_allowed");
  }
}
