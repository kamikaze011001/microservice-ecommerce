package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.NotFoundException;

public class EmailNotFoundException extends NotFoundException {

    public EmailNotFoundException(String email) {
        setCode("Can't find email " + email);
    }
}
