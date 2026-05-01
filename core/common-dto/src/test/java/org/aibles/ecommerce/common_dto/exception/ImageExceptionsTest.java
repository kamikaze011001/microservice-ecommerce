package org.aibles.ecommerce.common_dto.exception;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ImageExceptionsTest {

  @Test
  void typeNotAllowedIs400WithStableCode() {
    ImageTypeNotAllowedException ex = new ImageTypeNotAllowedException();
    assertThat(ex.getStatus()).isEqualTo(400);
    assertThat(ex.getCode()).isEqualTo("org.aibles.business.exception.ImageTypeNotAllowedException");
  }

  @Test
  void tooLargeIs400() {
    assertThat(new ImageTooLargeException().getStatus()).isEqualTo(400);
    assertThat(new ImageTooLargeException().getCode())
        .isEqualTo("org.aibles.business.exception.ImageTooLargeException");
  }

  @Test
  void keyForbiddenIs403() {
    assertThat(new ImageKeyForbiddenException().getStatus()).isEqualTo(403);
    assertThat(new ImageKeyForbiddenException().getCode())
        .isEqualTo("org.aibles.business.exception.ImageKeyForbiddenException");
  }

  @Test
  void notUploadedIs400() {
    assertThat(new ImageNotUploadedException().getStatus()).isEqualTo(400);
    assertThat(new ImageNotUploadedException().getCode())
        .isEqualTo("org.aibles.business.exception.ImageNotUploadedException");
  }

  @Test
  void storageUnavailableIs503() {
    assertThat(new StorageUnavailableException().getStatus()).isEqualTo(503);
    assertThat(new StorageUnavailableException().getCode())
        .isEqualTo("org.aibles.business.exception.StorageUnavailableException");
  }
}
