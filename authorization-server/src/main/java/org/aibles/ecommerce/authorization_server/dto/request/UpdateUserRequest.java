package org.aibles.ecommerce.authorization_server.dto.request;

import jakarta.validation.constraints.Pattern;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class UpdateUserRequest {

    @Pattern(regexp = "MALE|FEMALE")
    private String gender;

    private String name;

    private String address;
}
