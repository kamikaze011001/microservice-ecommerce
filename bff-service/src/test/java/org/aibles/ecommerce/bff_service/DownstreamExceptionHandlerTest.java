package org.aibles.ecommerce.bff_service;

import feign.FeignException;
import feign.Request;
import feign.Response;
import org.aibles.ecommerce.bff_service.exception.DownstreamExceptionHandler;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class DownstreamExceptionHandlerTest {

    private static final String ORDER_400 = """
            {"status":400,"code":"Bad Request","data":{"code":"validation.failed",\
            "message":"One or more fields are invalid.","errors":{"price":"must not be null"}}}""";

    /** Stands in for any bff endpoint whose Feign call failed downstream. */
    @RestController
    static class Failing {
        static FeignException next;

        @GetMapping("/call")
        void call() {
            throw next;
        }
    }

    private final MockMvc mvc = MockMvcBuilders.standaloneSetup(new Failing())
            .setControllerAdvice(new DownstreamExceptionHandler()).build();

    private static FeignException downstream(int status, String body) {
        Request request = Request.create(Request.HttpMethod.POST,
                "http://order-service:9696/order-service/v1/shopping-carts:add-item",
                Map.of(), null, StandardCharsets.UTF_8, null);
        Response.Builder response = Response.builder().status(status).reason("x").request(request)
                .headers(Map.of("Content-Type", List.of("application/json")));
        if (body != null) {
            response.body(body, StandardCharsets.UTF_8);
        }
        return FeignException.errorStatus("OrderFeignClient#addCartItem", response.build());
    }

    @Test
    void aDownstream400ReachesTheCallerAsA400WithItsValidationDetail() throws Exception {
        Failing.next = downstream(400, ORDER_400);

        mvc.perform(get("/call"))
                .andExpect(status().isBadRequest())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.data.code").value("validation.failed"))
                .andExpect(jsonPath("$.data.errors.price").value("must not be null"));
    }

    @Test
    void otherDownstream4xxKeepTheirStatusToo() throws Exception {
        Failing.next = downstream(404, "{\"status\":404,\"code\":\"Not Found\",\"data\":{\"code\":\"order.not_found\"}}");

        mvc.perform(get("/call"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.data.code").value("order.not_found"));
    }

    @Test
    void aBodyless4xxStillGetsABaseResponse() throws Exception {
        Failing.next = downstream(409, null);

        mvc.perform(get("/call"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.data.code").value("downstream.rejected"));
    }

    @Test
    void aDownstream5xxIsABadGatewayWithoutInternalUrls() throws Exception {
        Failing.next = downstream(503, "{\"secret\":\"http://order-service:9696 internals\"}");

        mvc.perform(get("/call"))
                .andExpect(status().isBadGateway())
                .andExpect(jsonPath("$.data.code").value("downstream.unavailable"))
                .andExpect(content().string(org.hamcrest.Matchers.not(org.hamcrest.Matchers.containsString("order-service"))));
    }
}
