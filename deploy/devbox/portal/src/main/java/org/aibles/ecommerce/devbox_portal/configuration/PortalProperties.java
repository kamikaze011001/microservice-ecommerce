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
        Links links) {

    public record Gitea(@NotBlank String url, @NotBlank String user, @NotBlank String password,
                        @NotBlank String owner, @NotBlank String envRepo, @NotBlank String branch) {
    }

    /** Browser-facing URLs of the other UIs (the `make devbox-open` forwards). */
    public record Links(String argocd, String gitea, String grafana, String registry) {
    }
}
