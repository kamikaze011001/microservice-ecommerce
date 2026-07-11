package org.aibles.ecommerce.common_dto.exception;

public class ImageKeyForbiddenException extends BaseException {

  public ImageKeyForbiddenException() {
    setStatus(403);
    setCode("common.image.key_forbidden");
  }
}
