package org.aibles.ecommerce.core_s3;

import java.time.Instant;

public record PresignedUpload(String uploadUrl, String objectKey, Instant expiresAt) {
}
