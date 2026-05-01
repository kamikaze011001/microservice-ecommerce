package org.aibles.ecommerce.authorization_server.service.impl;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.repository.master.MasterUserRepository;
import org.aibles.ecommerce.authorization_server.repository.slave.SlaveUserRepository;
import org.aibles.ecommerce.authorization_server.service.UserAvatarService;
import org.aibles.ecommerce.common_dto.exception.ImageKeyForbiddenException;
import org.aibles.ecommerce.common_dto.exception.ImageNotUploadedException;
import org.aibles.ecommerce.common_dto.exception.ImageTooLargeException;
import org.aibles.ecommerce.common_dto.exception.ImageTypeNotAllowedException;
import org.aibles.ecommerce.common_dto.exception.NotFoundException;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.core_s3.PresignedUpload;
import org.aibles.ecommerce.core_s3.S3Properties;
import org.aibles.ecommerce.core_s3.S3StorageService;

import java.util.UUID;

@Slf4j
@RequiredArgsConstructor
public class UserAvatarServiceImpl implements UserAvatarService {

    private final MasterUserRepository masterUserRepository;
    private final SlaveUserRepository slaveUserRepository;
    private final S3StorageService storage;
    private final S3Properties props;

    @Override
    public PresignedUploadResponse presign(String userId, PresignImageRequest request) {
        log.info("(presign avatar)userId: {}, contentType: {}", userId, request.getContentType());
        slaveUserRepository.findById(userId).orElseThrow(NotFoundException::new);
        validate(request);
        String ext = extensionFor(request.getContentType());
        String key = "avatars/" + userId + "/" + UUID.randomUUID() + "." + ext;
        PresignedUpload signed = storage.presignUpload(key, request.getContentType());
        return new PresignedUploadResponse(signed.uploadUrl(), signed.objectKey(), signed.expiresAt());
    }

    @Override
    public User attach(String userId, AttachImageRequest request) {
        log.info("(attach avatar)userId: {}, objectKey: {}", userId, request.getObjectKey());
        User user = slaveUserRepository.findById(userId).orElseThrow(NotFoundException::new);
        String prefix = "avatars/" + userId + "/";
        if (!request.getObjectKey().startsWith(prefix)) {
            throw new ImageKeyForbiddenException();
        }
        if (!storage.objectExists(request.getObjectKey())) {
            throw new ImageNotUploadedException();
        }
        user.setAvatarUrl(storage.publicUrl(request.getObjectKey()));
        return masterUserRepository.save(user);
    }

    private void validate(PresignImageRequest req) {
        if (!props.getAllowedTypes().contains(req.getContentType())) {
            throw new ImageTypeNotAllowedException();
        }
        if (req.getSizeBytes() > props.getMaxUploadSize()) {
            throw new ImageTooLargeException();
        }
    }

    private static String extensionFor(String contentType) {
        return switch (contentType) {
            case "image/jpeg" -> "jpg";
            case "image/png" -> "png";
            case "image/webp" -> "webp";
            default -> throw new ImageTypeNotAllowedException();
        };
    }
}
