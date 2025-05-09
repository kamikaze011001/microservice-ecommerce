package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.ConflictException;

public class UserAlreadyExistedException extends ConflictException {
    public UserAlreadyExistedException() {
        setCode("Email or Username already existed");
    }
}
