package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class PasswordInvalidException extends BadRequestException {
    public PasswordInvalidException() {
        setCode("Your password is incorrect");
    }
}
