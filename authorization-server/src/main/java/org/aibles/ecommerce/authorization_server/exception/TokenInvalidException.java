package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.UnauthorizedException;

public class TokenInvalidException extends UnauthorizedException {

    public TokenInvalidException() {
        setCode("Your token is invalid");
    }
}
