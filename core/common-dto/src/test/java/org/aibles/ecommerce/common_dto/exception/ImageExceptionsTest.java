package org.aibles.ecommerce.common_dto.exception;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ImageExceptionsTest {

  @Test
  void typeNotAllowedIs400WithStableCode() {
    ImageTypeNotAllowedException ex = new ImageTypeNotAllowedException();
    assertThat(ex.getStatus()).isEqualTo(400);
    assertThat(ex.getCode()).isEqualTo("common.image.type_not_allowed");
  }

  @Test
  void tooLargeIs400() {
    assertThat(new ImageTooLargeException().getStatus()).isEqualTo(400);
    assertThat(new ImageTooLargeException().getCode())
        .isEqualTo("common.image.too_large");
  }

  @Test
  void keyForbiddenIs403() {
    assertThat(new ImageKeyForbiddenException().getStatus()).isEqualTo(403);
    assertThat(new ImageKeyForbiddenException().getCode())
        .isEqualTo("common.image.key_forbidden");
  }

  @Test
  void notUploadedIs400() {
    assertThat(new ImageNotUploadedException().getStatus()).isEqualTo(400);
    assertThat(new ImageNotUploadedException().getCode())
        .isEqualTo("common.image.not_uploaded");
  }

  @Test
  void storageUnavailableIs503() {
    assertThat(new StorageUnavailableException().getStatus()).isEqualTo(503);
    assertThat(new StorageUnavailableException().getCode())
        .isEqualTo("org.aibles.business.exception.StorageUnavailableException");
  }
}
