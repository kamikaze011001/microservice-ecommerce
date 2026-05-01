package org.aibles.ecommerce.common_dto.exception;

public class ImageKeyForbiddenException extends BaseException {

  public ImageKeyForbiddenException() {
    setStatus(403);
    setCode("org.aibles.business.exception.ImageKeyForbiddenException");
  }
}
