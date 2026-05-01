package org.aibles.ecommerce.common_dto.exception;

public class StorageUnavailableException extends BaseException {

  public StorageUnavailableException() {
    setStatus(503);
    setCode("org.aibles.business.exception.StorageUnavailableException");
  }
}
