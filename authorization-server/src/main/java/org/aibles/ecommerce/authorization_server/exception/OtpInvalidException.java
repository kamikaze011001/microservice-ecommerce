package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class OtpInvalidException extends BadRequestException {

    public OtpInvalidException() {
        setCode("Your otp is invalid");
    }
}
