package org.aibles.ecommerce.devbox_portal.client;

import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.jsonPath;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

class GiteaClientTest {

    private static final String BASE = "http://gitea";
    private static final String FILE_URL = BASE + "/api/v1/repos/devbox/env-config/contents/envs/prod-like/services/order-service.yaml";
    private static final String CONTENT = "apps:\n  order-service:\n    image:\n      tag: ac48ad8\n";

    private MockRestServiceServer server;
    private GiteaClient client;

    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder().baseUrl(BASE);
        server = MockRestServiceServer.bindTo(builder).build();
        client = new GiteaClient(builder.build(),
                new PortalProperties.Gitea(BASE, "devbox", "pw", "devbox", "env-config", "main"));
    }

    @Test
    void readDecodesGiteasLineWrappedBase64() {
        // Gitea wraps base64 every 60 chars; a plain decoder rejects the newlines.
        String wrapped = Base64.getMimeEncoder(60, "\n".getBytes())
                .encodeToString(CONTENT.getBytes(StandardCharsets.UTF_8));
        server.expect(requestTo(FILE_URL + "?ref=main")).andExpect(method(HttpMethod.GET))
                .andRespond(withSuccess("{\"content\":\"" + wrapped.replace("\n", "\\n") + "\",\"sha\":\"blob-1\"}",
                        MediaType.APPLICATION_JSON));

        GiteaClient.RepoFile file = client.read("envs/prod-like/services/order-service.yaml");

        assertThat(file.content()).isEqualTo(CONTENT);
        assertThat(file.sha()).isEqualTo("blob-1");
    }

    @Test
    void updateSendsTheReadShaSoAConcurrentChangeIsDetected() {
        server.expect(requestTo(FILE_URL)).andExpect(method(HttpMethod.PUT))
                .andExpect(jsonPath("$.sha").value("blob-1"))
                .andExpect(jsonPath("$.branch").value("main"))
                .andExpect(jsonPath("$.content").value(Base64.getEncoder().encodeToString("new".getBytes())))
                .andExpect(jsonPath("$.message").value("deploy x a → b\n\nbody"))
                .andRespond(withSuccess("{\"commit\":{\"sha\":\"c0ffee\"}}", MediaType.APPLICATION_JSON));

        String sha = client.update(new GiteaClient.RepoFile("envs/prod-like/services/order-service.yaml", CONTENT, "blob-1"),
                "new", "deploy x a → b", "body");

        assertThat(sha).isEqualTo("c0ffee");
        server.verify();
    }

    @Test
    void aStaleShaBecomesAConflictNotAnOverwrite() {
        server.expect(requestTo(FILE_URL)).andExpect(method(HttpMethod.PUT))
                .andRespond(withStatus(HttpStatus.CONFLICT));

        assertThatThrownBy(() -> client.update(
                new GiteaClient.RepoFile("envs/prod-like/services/order-service.yaml", CONTENT, "old"), "x", "s", "b"))
                .isInstanceOf(PortalException.class)
                .satisfies(e -> assertThat(((PortalException) e).status()).isEqualTo(HttpStatus.CONFLICT))
                .hasMessageContaining("changed since it was read");
    }

    @Test
    void commitsAreCappedEvenWhenGiteaIgnoresLimit() {
        String commit = "{\"sha\":\"%s\",\"commit\":{\"message\":\"m\\n\\nbody\",\"author\":{\"name\":\"a\",\"date\":\"d\"}}}";
        server.expect(requestTo(org.hamcrest.Matchers.startsWith(BASE + "/api/v1/repos/devbox/env-config/commits")))
                .andRespond(withSuccess("[" + String.join(",", commit.formatted("1"), commit.formatted("2"),
                        commit.formatted("3"), commit.formatted("4")) + "]", MediaType.APPLICATION_JSON));

        assertThat(client.commits("envs/prod-like", 2))
                .extracting(GiteaClient.Commit::sha).containsExactly("1", "2");
    }

    @Test
    void aMissingFileIs404() {
        server.expect(requestTo(FILE_URL + "?ref=main")).andRespond(withStatus(HttpStatus.NOT_FOUND));

        assertThatThrownBy(() -> client.read("envs/prod-like/services/order-service.yaml"))
                .isInstanceOf(PortalException.class)
                .satisfies(e -> assertThat(((PortalException) e).status()).isEqualTo(HttpStatus.NOT_FOUND));
    }
}
