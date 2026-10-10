package org.aibles.ecommerce.devbox_portal.controller;

import com.sun.net.httpserver.HttpServer;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;
import org.springframework.mock.web.MockHttpServletRequest;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Against a real local HTTP server standing in for an env's gateway. */
class GatewayProxyControllerTest {

    private HttpServer gateway;
    private final AtomicReference<String> seen = new AtomicReference<>();
    private GatewayProxyController proxy;

    @BeforeEach
    void setUp() throws Exception {
        gateway = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        gateway.createContext("/", ex -> {
            String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            seen.set(ex.getRequestMethod() + " " + ex.getRequestURI() + " auth=" + ex.getRequestHeaders().getFirst("Authorization")
                    + " cookie=" + ex.getRequestHeaders().getFirst("Cookie") + " body=" + body);
            byte[] out = "{\"status\":201}".getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", "application/json");
            ex.sendResponseHeaders(201, out.length);
            ex.getResponseBody().write(out);
            ex.close();
        });
        gateway.start();
        PortalProperties props = new PortalProperties(null, "r", "m", "argocd", null, null,
                "http://127.0.0.1:" + gateway.getAddress().getPort());
        proxy = new GatewayProxyController(props);
    }

    @AfterEach
    void tearDown() {
        gateway.stop(0);
    }

    @Test
    void forwardsPathQueryMethodBodyAndToken_butNotCookies() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/api/envs/preview-ui/gateway/order-service/v1/orders");
        req.setQueryString("page=1&size=5");
        req.addHeader("Authorization", "Bearer abc");
        req.addHeader("Cookie", "portal-session=secret");
        req.addHeader("Content-Type", "application/json");

        ResponseEntity<byte[]> res = proxy.proxy("preview-ui", req, "{\"x\":1}".getBytes(StandardCharsets.UTF_8));

        assertThat(seen.get()).isEqualTo("POST /order-service/v1/orders?page=1&size=5 auth=Bearer abc cookie=null body={\"x\":1}");
        assertThat(res.getStatusCode().value()).isEqualTo(201);
        assertThat(res.getHeaders().getContentType()).hasToString("application/json");
        assertThat(new String(res.getBody(), StandardCharsets.UTF_8)).isEqualTo("{\"status\":201}");
    }

    @Test
    void colonActionPathsPassThroughUntouched() {
        MockHttpServletRequest req = new MockHttpServletRequest("POST", "/api/envs/prod-like/gateway/authorization-server/v1/auth:login");

        proxy.proxy("prod-like", req, null);

        assertThat(seen.get()).startsWith("POST /authorization-server/v1/auth:login ");
    }

    @Test
    void theNamespaceFollowsTheEnv() {
        PortalProperties props = new PortalProperties(null, "r", "m", "argocd", null, null,
                "http://gateway.{namespace}.svc.cluster.local:6868");
        GatewayProxyController p = new GatewayProxyController(props);

        assertThat(p.gatewayBase("prod-like")).isEqualTo("http://gateway.apps.svc.cluster.local:6868");
        assertThat(p.gatewayBase("preview-ui")).isEqualTo("http://gateway.apps-preview-ui.svc.cluster.local:6868");
    }

    @Test
    void anythingButAnEnvNameIsRefused() {
        MockHttpServletRequest req = new MockHttpServletRequest("GET", "/api/envs/x/gateway/");
        assertThatThrownBy(() -> proxy.proxy("kube-system", req, null)).isInstanceOf(IllegalArgumentException.class);
    }
}
