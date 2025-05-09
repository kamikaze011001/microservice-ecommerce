package org.aibles.ecommerce.authorization_server.dto.response;

import lombok.Data;
import lombok.EqualsAndHashCode;
import lombok.experimental.SuperBuilder;

@EqualsAndHashCode(callSuper = true)
@Data
@SuperBuilder
public class RefreshTokenResponse extends LoginResponse {
}
