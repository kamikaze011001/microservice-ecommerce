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

    /** What the page needs once: where the other UIs are, and the preview cap. */
    public record Info(Links links, int maxPreviews, boolean jobsEnabled) {
    }

    public record JobRequest(@NotBlank String kind, @NotBlank String target) {
    }

    /**
     * One runner Job. {@code status}: PENDING (pod starting), RUNNING,
     * SUCCEEDED, FAILED. Times are ISO-8601, null until known.
     */
    public record JobView(String name, String kind, String title, String target, String status,
                          String startedAt, String finishedAt) {
    }
}
