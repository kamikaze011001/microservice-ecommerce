package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class OldPasswordInvalidException extends BadRequestException {

    public OldPasswordInvalidException() {
        setCode("Old password is incorrect");
    }
}
