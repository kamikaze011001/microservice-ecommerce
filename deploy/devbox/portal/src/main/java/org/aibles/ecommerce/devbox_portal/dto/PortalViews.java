package org.aibles.ecommerce.devbox_portal.dto;

import jakarta.validation.constraints.NotBlank;

import java.util.List;

/**
 * What the portal's page reads and sends. Serialized snake_case
 * (spring.jackson.property-naming-strategy), like every DTO in this repo.
 */
public final class PortalViews {

    private PortalViews() {
    }

    /** One service in one env: what git says vs what Argo CD reports. */
    public record ServiceView(String name, String application, String desiredTag,
                              String sync, String health, List<String> runningImages) {
    }

    public record EnvView(String name, List<ServiceView> services) {
    }

    /** A registry tag and the envs whose service file pins it right now. */
    public record TagView(String tag, List<String> usedBy) {
    }

    public record DeployRequest(@NotBlank String tag) {
    }

    /**
     * {@code changed=false}: the env already pinned this tag, nothing committed.
     * {@code refreshed=false}: committed, but Argo CD wasn't nudged — it will
     * still pick the commit up on its own 60s poll.
     */
    public record DeployResult(String env, String service, String previousTag, String tag,
                               String commit, boolean changed, boolean refreshed) {
    }

    public record Links(String argocd, String gitea, String grafana, String registry) {
    }
}
