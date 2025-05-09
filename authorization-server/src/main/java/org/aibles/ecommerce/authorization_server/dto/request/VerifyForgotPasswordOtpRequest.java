package org.aibles.ecommerce.authorization_server.dto.request;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.authorization_server.annotation.ValidEmail;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class VerifyForgotPasswordOtpRequest {

    @ValidEmail
    @NotBlank
    private String email;

    @NotBlank
    private String otp;
}
