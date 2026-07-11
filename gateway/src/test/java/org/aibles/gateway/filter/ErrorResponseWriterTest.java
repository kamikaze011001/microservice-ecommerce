package org.aibles.gateway.filter;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ErrorResponseWriterTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void body_hasNestedContractShape() {
        Map<String, Object> body = ErrorResponseWriter.body(
                HttpStatus.UNAUTHORIZED, "auth.token_missing", ErrorResponseWriter.MSG_TOKEN_MISSING);

        assertThat(body.get("status")).isEqualTo(401);
        assertThat(body.get("code")).isEqualTo("Unauthorized");
        assertThat(body).doesNotContainKeys("error", "message", "path"); // old shape is gone

        @SuppressWarnings("unchecked")
        Map<String, Object> data = (Map<String, Object>) body.get("data");
        assertThat(data.get("code")).isEqualTo("auth.token_missing");
        assertThat(data.get("message")).isEqualTo("Authentication is required.");
    }

    @Test
    void body_serializesToNestedJsonInContractOrder() throws Exception {
        String json = objectMapper.writeValueAsString(ErrorResponseWriter.body(
                HttpStatus.FORBIDDEN, "auth.forbidden", ErrorResponseWriter.MSG_FORBIDDEN));

        assertThat(json).isEqualTo(
                "{\"status\":403,\"code\":\"Forbidden\","
                        + "\"data\":{\"code\":\"auth.forbidden\","
                        + "\"message\":\"You do not have permission to access this resource.\"}}");
    }

    @Test
    void body_hasNestedContractShape_forBadRequest() {
        Map<String, Object> body = ErrorResponseWriter.body(
                HttpStatus.BAD_REQUEST, "common.bad_request", ErrorResponseWriter.MSG_BAD_REQUEST);

        assertThat(body.get("status")).isEqualTo(400);
        assertThat(body.get("code")).isEqualTo("Bad Request");

        @SuppressWarnings("unchecked")
        Map<String, Object> data = (Map<String, Object>) body.get("data");
        assertThat(data.get("code")).isEqualTo("common.bad_request");
        assertThat(data.get("message")).isEqualTo("The request was invalid.");
    }
}
