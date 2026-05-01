package org.aibles.ecommerce.common_dto.exception;

public class ImageNotUploadedException extends BaseException {

  public ImageNotUploadedException() {
    setStatus(400);
    setCode("org.aibles.business.exception.ImageNotUploadedException");
  }
}
