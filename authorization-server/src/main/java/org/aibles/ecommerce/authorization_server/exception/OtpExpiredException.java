package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class OtpExpiredException extends BadRequestException {

    public OtpExpiredException() {
        setCode("Otp is expired");
    }
}
