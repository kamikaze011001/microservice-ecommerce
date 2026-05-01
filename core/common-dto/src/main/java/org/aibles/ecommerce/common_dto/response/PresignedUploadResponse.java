package org.aibles.ecommerce.common_dto.response;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.time.Instant;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class PresignedUploadResponse {

    private String uploadUrl;
    private String objectKey;
    private Instant expiresAt;
}
