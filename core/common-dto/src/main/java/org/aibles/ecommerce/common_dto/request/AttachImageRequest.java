package org.aibles.ecommerce.common_dto.request;

import jakarta.validation.constraints.NotBlank;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class AttachImageRequest {

    @NotBlank
    private String objectKey;
}
