package org.aibles.ecommerce.authorization_server.dto.request;

import com.fasterxml.jackson.annotation.JsonIgnore;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.NotBlank;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.authorization_server.annotation.ValidEmail;
import org.aibles.ecommerce.authorization_server.constant.OTPType;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class ResendOTPRequest {

    @NotBlank
    private String type;

    @NotBlank
    @ValidEmail
    private String email;

    @AssertTrue
    @JsonIgnore
    private boolean isTypeValid() {
        return OTPType.resolve(type) != null;
    }
}
