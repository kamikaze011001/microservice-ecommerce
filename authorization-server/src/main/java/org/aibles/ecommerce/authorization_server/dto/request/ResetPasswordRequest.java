package org.aibles.ecommerce.authorization_server.dto.request;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.NotBlank;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.authorization_server.annotation.ValidEmail;
import org.aibles.ecommerce.authorization_server.annotation.ValidPassword;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class ResetPasswordRequest {

    @NotBlank
    private String resetPasswordKey;

    @NotBlank
    @ValidEmail
    private String email;

    @NotBlank
    @ValidPassword
    private String password;

    @NotBlank
    @ValidPassword
    private String confirmPassword;

    @AssertTrue(message = "Confirm password must equal password")
    @JsonIgnore
    private boolean isConfirmPasswordEqual() {
        return password.equals(confirmPassword);
    }
}
