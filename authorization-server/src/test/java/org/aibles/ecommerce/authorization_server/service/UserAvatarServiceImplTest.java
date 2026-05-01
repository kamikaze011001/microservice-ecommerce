package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.repository.master.MasterUserRepository;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveUserRepository;
import org.aibles.ecommerce.authorization_server.service.impl.UserAvatarServiceImpl;
import org.aibles.ecommerce.common_dto.exception.ImageKeyForbiddenException;
import org.aibles.ecommerce.common_dto.exception.ImageNotUploadedException;
import org.aibles.ecommerce.common_dto.exception.ImageTooLargeException;
import org.aibles.ecommerce.common_dto.exception.ImageTypeNotAllowedException;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.core_s3.PresignedUpload;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class UserAvatarServiceImplTest {

    private MasterUserRepository masterUserRepo;
    private SlaveUserRepository slaveUserRepo;
    private S3StorageService storage;
    private S3Properties props;
    private UserAvatarService service;

    @BeforeEach
    void setUp() {
        masterUserRepo = mock(MasterUserRepository.class);
        slaveUserRepo = mock(SlaveUserRepository.class);
        storage = mock(S3StorageService.class);
        props = new S3Properties();
        props.setMaxUploadSize(5L * 1024 * 1024);
        props.setAllowedTypes(List.of("image/jpeg", "image/png", "image/webp"));
        props.setPresignTtl(Duration.ofMinutes(5));
        props.setPublicBaseUrl("http://localhost:9000/ecommerce-media");
        service = new UserAvatarServiceImpl(masterUserRepo, slaveUserRepo, storage, props);
    }

    @Test
    void presignReturnsAvatarScopedKey() {
        User u = new User();
        u.setId("u1");
        when(slaveUserRepo.findById("u1")).thenReturn(Optional.of(u));
        when(storage.presignUpload(anyString(), eq("image/png")))
            .thenAnswer(inv -> new PresignedUpload("http://signed", inv.getArgument(0), Instant.now().plusSeconds(300)));

        PresignedUploadResponse resp = service.presign("u1", new PresignImageRequest("image/png", 1024L));

        assertThat(resp.getObjectKey()).startsWith("avatars/u1/");
        assertThat(resp.getObjectKey()).endsWith(".png");
    }

    @Test
    void presignRejectsUnsupportedType() {
        User u = new User();
        u.setId("u1");
        when(slaveUserRepo.findById("u1")).thenReturn(Optional.of(u));
        assertThatThrownBy(() -> service.presign("u1", new PresignImageRequest("application/pdf", 100L)))
            .isInstanceOf(ImageTypeNotAllowedException.class);
    }

    @Test
    void presignRejectsOversize() {
        User u = new User();
        u.setId("u1");
        when(slaveUserRepo.findById("u1")).thenReturn(Optional.of(u));
        assertThatThrownBy(() -> service.presign("u1", new PresignImageRequest("image/jpeg", 10L * 1024 * 1024)))
            .isInstanceOf(ImageTooLargeException.class);
    }

    @Test
    void attachRejectsKeyForOtherUser() {
        User u = new User();
        u.setId("u1");
        when(slaveUserRepo.findById("u1")).thenReturn(Optional.of(u));
        assertThatThrownBy(() -> service.attach("u1", new AttachImageRequest("avatars/u2/x.png")))
            .isInstanceOf(ImageKeyForbiddenException.class);
    }

    @Test
    void attachRejectsWhenObjectMissing() {
        User u = new User();
        u.setId("u1");
        when(slaveUserRepo.findById("u1")).thenReturn(Optional.of(u));
        when(storage.objectExists("avatars/u1/x.png")).thenReturn(false);
        assertThatThrownBy(() -> service.attach("u1", new AttachImageRequest("avatars/u1/x.png")))
            .isInstanceOf(ImageNotUploadedException.class);
    }

    @Test
    void attachPersistsAvatarUrl() {
        User u = new User();
        u.setId("u1");
        when(slaveUserRepo.findById("u1")).thenReturn(Optional.of(u));
        when(storage.objectExists("avatars/u1/x.png")).thenReturn(true);
        when(storage.publicUrl("avatars/u1/x.png"))
            .thenReturn("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
        when(masterUserRepo.save(any())).thenAnswer(inv -> inv.getArgument(0));

        service.attach("u1", new AttachImageRequest("avatars/u1/x.png"));

        assertThat(u.getAvatarUrl()).isEqualTo("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
    }
}
