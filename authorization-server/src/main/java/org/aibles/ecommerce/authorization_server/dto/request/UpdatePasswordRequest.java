package org.aibles.ecommerce.authorization_server.dto.request;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.NotBlank;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.authorization_server.annotation.ValidPassword;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class UpdatePasswordRequest {

    @NotBlank
    @ValidPassword
    private String oldPassword;

    @NotBlank
    @ValidPassword
    private String newPassword;

    @NotBlank
    @ValidPassword
    private String confirmNewPassword;

    @AssertTrue(message = "Confirm password must equal password")
    @JsonIgnore
    private boolean isConfirmPasswordEqual() {
        return newPassword.equals(confirmNewPassword);
    }
}
