package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class InvalidResetPasswordKey extends BadRequestException {

    public InvalidResetPasswordKey() {
        setCode("Your reset password key is invalid");
    }
}
