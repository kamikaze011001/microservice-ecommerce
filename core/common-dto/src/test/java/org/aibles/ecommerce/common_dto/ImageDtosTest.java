package org.aibles.ecommerce.common_dto;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class ImageDtosTest {

    private final ObjectMapper mapper = new ObjectMapper()
        .findAndRegisterModules()
        .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

    @Test
    void presignImageRequestSerializesAndBindsValidation() throws Exception {
        String json = "{\"contentType\":\"image/jpeg\",\"sizeBytes\":1234}";
        PresignImageRequest req = mapper.readValue(json, PresignImageRequest.class);
        assertThat(req.getContentType()).isEqualTo("image/jpeg");
        assertThat(req.getSizeBytes()).isEqualTo(1234L);
    }

    @Test
    void attachImageRequestRoundTrips() throws Exception {
        AttachImageRequest req = mapper.readValue(
            "{\"objectKey\":\"products/abc/x.jpg\"}", AttachImageRequest.class);
        assertThat(req.getObjectKey()).isEqualTo("products/abc/x.jpg");
    }

    @Test
    void presignedUploadResponseRoundTrips() throws Exception {
        PresignedUploadResponse r = new PresignedUploadResponse(
            "http://signed", "products/abc/x.jpg", Instant.parse("2026-04-27T00:00:00Z"));
        String json = mapper.writeValueAsString(r);
        assertThat(json).contains("\"uploadUrl\":\"http://signed\"");
        assertThat(json).contains("\"objectKey\":\"products/abc/x.jpg\"");
        assertThat(json).contains("\"expiresAt\":\"2026-04-27T00:00:00Z\"");
    }
}
