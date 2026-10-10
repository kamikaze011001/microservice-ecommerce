package org.aibles.ecommerce.devbox_portal.dto;

import jakarta.validation.constraints.NotBlank;
import org.aibles.ecommerce.devbox_portal.client.GiteaClient;

import java.util.List;
import java.util.Map;

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

    /** {@code params}: kind-specific, e.g. perf {scenario, profile}. */
    public record JobRequest(@NotBlank String kind, @NotBlank String target, Map<String, String> params) {
    }

    /**
     * One runner Job. {@code status}: PENDING (pod starting), RUNNING,
     * SUCCEEDED, FAILED. Times are ISO-8601, null until known.
     */
    public record JobView(String name, String kind, String title, String target, String status,
                          String startedAt, String finishedAt) {
    }

    /** A platform UI and its login (null username/password = no login needed). */
    public record ToolView(String key, String name, String url, String purpose, String username, String password) {
    }

    /**
     * A service's settings in one env. {@code spring}/{@code envVars}: this service's
     * own (editable); {@code inheritedSpring}: the env-wide defaults it gets anyway.
     * {@code fileSha}: send back on save, so a concurrent change is a 409.
     */
    public record SettingsView(String env, String service, boolean staticBuild, Map<String, String> spring,
                               Map<String, String> envVars, Map<String, String> inheritedSpring, String fileSha,
                               List<GiteaClient.Commit> history) {
    }

    public record SettingsRequest(Map<String, String> spring, Map<String, String> envVars, String baseSha) {
    }

    public record RevertRequest(@NotBlank String commit) {
    }

    public record SettingsResult(String env, String service, String commit, boolean changed, boolean refreshed,
                                 String summary) {
    }
}
