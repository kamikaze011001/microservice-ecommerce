package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class AccountNotActivatedException extends BadRequestException {

    public AccountNotActivatedException() {
        setCode("Your account is not activated");
    }
}
