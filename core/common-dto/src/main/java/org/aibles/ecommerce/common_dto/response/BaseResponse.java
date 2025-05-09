package org.aibles.ecommerce.common_dto.response;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.springframework.http.HttpStatus;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class BaseResponse {

    private int status;

    private String code;

    private Object data;

    public static BaseResponse from(int status, String code, Object data) {
        return new BaseResponse(status, code, data);
    }

    public static BaseResponse ok(Object data) {
        return new BaseResponse(HttpStatus.OK.value(), HttpStatus.OK.getReasonPhrase(), data);
    }

    public static BaseResponse ok() {
        return new BaseResponse(HttpStatus.OK.value(), HttpStatus.OK.getReasonPhrase(), null);
    }

    public static BaseResponse created(Object data) {
        return new BaseResponse(HttpStatus.CREATED.value(), HttpStatus.CREATED.getReasonPhrase(), data);
    }

    public static BaseResponse badRequest(Object data) {
        return new BaseResponse(HttpStatus.BAD_REQUEST.value(), HttpStatus.BAD_REQUEST.getReasonPhrase(), data);
    }

    public static BaseResponse unauthorized(Object data) {
        return new BaseResponse(HttpStatus.UNAUTHORIZED.value(), HttpStatus.UNAUTHORIZED.getReasonPhrase(), data);
    }

    public static BaseResponse internalServerError(Object data) {
        return new BaseResponse(HttpStatus.INTERNAL_SERVER_ERROR.value(), HttpStatus.INTERNAL_SERVER_ERROR.getReasonPhrase(), data);
    }

    public static BaseResponse notFound(Object data) {
        return new BaseResponse(HttpStatus.NOT_FOUND.value(), HttpStatus.NOT_FOUND.getReasonPhrase(), data);
    }
}
