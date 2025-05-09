package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class InvalidRoleIdException extends BadRequestException {

    public InvalidRoleIdException() {
        setCode("invalid_role_name_exception");
    }
}
