package org.aibles.ecommerce.authorization_server.exception;

import org.aibles.ecommerce.common_dto.exception.BadRequestException;

public class OtpStillValidException extends BadRequestException {

    public OtpStillValidException() {
        setCode("You have a otp that still in use");
    }
}
