package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;

public interface UserAvatarService {
    PresignedUploadResponse presign(String userId, PresignImageRequest request);
    User attach(String userId, AttachImageRequest request);
}
