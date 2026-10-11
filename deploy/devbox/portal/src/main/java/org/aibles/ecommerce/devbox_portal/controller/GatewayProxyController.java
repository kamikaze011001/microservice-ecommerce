package org.aibles.ecommerce.devbox_portal.controller;

import jakarta.servlet.http.HttpServletRequest;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.List;
import java.util.regex.Pattern;

/**
 * The API console's way into an env: /api/envs/{env}/gateway/** → that env's
 * gateway Service, from inside the cluster. So the console works on
 * localhost:8282 with no /etc/hosts or tunnel, and Swagger's "Try it out" is
 * same-origin (no CORS). It is exactly as powerful as the env's public API —
 * the gateway still authenticates every call.
 */
@Slf4j
@RestController
public class GatewayProxyController {

    private static final Pattern ENV = Pattern.compile("prod-like|preview-[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?");
    /** Only what an API call needs — never the portal's own cookies or Host. */
    private static final List<String> FORWARDED_REQUEST = List.of("authorization", "content-type", "accept");
    private static final List<String> FORWARDED_RESPONSE = List.of("content-type", "location");

    private final PortalProperties properties;
    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .followRedirects(HttpClient.Redirect.NEVER)   // show the redirect, as a browser devtools would
            .build();

    public GatewayProxyController(PortalProperties properties) {
        this.properties = properties;
    }

    @RequestMapping("/api/envs/{env}/gateway/**")
    public ResponseEntity<byte[]> proxy(@PathVariable String env, HttpServletRequest request,
                                        @RequestBody(required = false) byte[] body) {
        if (!ENV.matcher(env).matches()) {
            throw new IllegalArgumentException("not an env: " + env);
        }
        String prefix = "/api/envs/" + env + "/gateway";
        String path = request.getRequestURI().substring(request.getRequestURI().indexOf(prefix) + prefix.length());
        if (path.isEmpty()) {
            path = "/";
        }
        String query = request.getQueryString() == null ? "" : "?" + request.getQueryString();
        URI target = URI.create(gatewayBase(env) + path + query);

        HttpRequest.Builder out = HttpRequest.newBuilder(target).timeout(Duration.ofSeconds(60));
        for (String h : FORWARDED_REQUEST) {
            String v = request.getHeader(h);
            if (v != null) {
                out.header(h, v);
            }
        }
        out.method(request.getMethod(), body == null || body.length == 0
                ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofByteArray(body));

        try {
            HttpResponse<byte[]> res = http.send(out.build(), HttpResponse.BodyHandlers.ofByteArray());
            HttpHeaders headers = new HttpHeaders();
            for (String h : FORWARDED_RESPONSE) {
                res.headers().firstValue(h).ifPresent(v -> headers.set(h, v));
            }
            return ResponseEntity.status(res.statusCode()).headers(headers).body(res.body());
        } catch (IOException e) {
            throw new PortalException(HttpStatus.BAD_GATEWAY,
                    env + "'s gateway is unreachable (" + e.getClass().getSimpleName() + ") — is the env up?", e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new PortalException(HttpStatus.BAD_GATEWAY, "interrupted calling " + env + "'s gateway", e);
        }
    }

    /** prod-like lives in `apps`; a preview in `apps-preview-<name>` (env_gen.py). */
    String gatewayBase(String env) {
        String ns = env.equals("prod-like") ? "apps" : "apps-" + env;
        return properties.gatewayUrl().replace("{namespace}", ns);
    }
}
