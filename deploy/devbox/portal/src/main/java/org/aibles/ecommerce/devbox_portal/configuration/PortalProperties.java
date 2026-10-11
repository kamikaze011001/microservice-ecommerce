package org.aibles.ecommerce.devbox_portal.configuration;

import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Where the platform lives. In-cluster defaults are in application.yml; the
 * Gitea password comes from the {@code devbox-portal} Secret (devbox.sh).
 */
@Validated
@ConfigurationProperties("devbox")
public record PortalProperties(
        Gitea gitea,
        @NotBlank String registryUrl,
        @NotBlank String metricsUrl,
        @NotBlank String argoNamespace,
        Links links,
        Runner runner,
        @NotBlank String gatewayUrl,
        Assets assets) {

    /** {@code codeRepo}: where developers push branches for the Build page (and `make devbox-push`). */
    public record Gitea(@NotBlank String url, @NotBlank String user, @NotBlank String password,
                        @NotBlank String owner, @NotBlank String envRepo, @NotBlank String branch,
                        @NotBlank String codeRepo) {
    }

    /**
     * The Job that runs devbox.sh for the page. {@code image} blank = jobs off
     * (e.g. the portal run on a laptop). {@code maxPreviews} is the laptop's
     * memory budget: each preview is a full copy of the app.
     */
    public record Runner(String image, @NotBlank String namespace, @NotBlank String serviceAccount, int maxPreviews) {
    }

    /** Where the image keeps api-tests/ and deploy/k6-stress/, and the k6 binary (Dockerfile). */
    public record Assets(String apiTestsDir, String k6Dir, String k6Binary) {
    }

    /** Browser-facing URLs of the other UIs (ingress hosts, through the minikube tunnel). */
    public record Links(String argocd, String gitea, String grafana, String registry) {
    }
}
