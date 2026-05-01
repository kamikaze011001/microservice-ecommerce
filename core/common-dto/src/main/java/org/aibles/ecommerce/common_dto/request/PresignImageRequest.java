package org.aibles.ecommerce.common_dto.request;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Positive;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class PresignImageRequest {

    @NotBlank
    private String contentType;

    @Positive
    @Min(1)
    private long sizeBytes;
}
