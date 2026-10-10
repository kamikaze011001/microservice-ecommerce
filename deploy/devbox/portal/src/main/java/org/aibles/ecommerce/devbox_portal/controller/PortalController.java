package org.aibles.ecommerce.devbox_portal.controller;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Pattern;
import org.aibles.ecommerce.devbox_portal.client.GiteaClient;
import org.aibles.ecommerce.devbox_portal.client.MetricsClient;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.DeployRequest;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.DeployResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.EnvView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.Links;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.TagView;
import org.aibles.ecommerce.devbox_portal.service.EnvService;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * The portal's JSON API. Absolute method paths, no class-level mapping — the
 * repo rule for colon actions (`:deploy`), see root CLAUDE.md.
 *
 * <p>Env and service names go into Gitea paths, so they are validated against
 * the same grammar env_gen.py enforces — no `..` or `/` can reach a path.
 */
@Validated
@RestController
public class PortalController {

    private static final String NAME = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?";

    private final EnvService envService;
    private final PortalProperties properties;

    public PortalController(EnvService envService, PortalProperties properties) {
        this.envService = envService;
        this.properties = properties;
    }

    @GetMapping("/api/envs")
    public List<EnvView> envs() {
        return envService.envs();
    }

    @GetMapping("/api/envs/{env}/history")
    public List<GiteaClient.Commit> history(@PathVariable @Pattern(regexp = NAME) String env,
                                            @RequestParam(defaultValue = "20") @Min(1) @Max(100) int limit) {
        return envService.history(env, limit);
    }

    @GetMapping("/api/services/{service}/tags")
    public List<TagView> tags(@PathVariable @Pattern(regexp = NAME) String service) {
        return envService.tags(service);
    }

    @PostMapping("/api/envs/{env}/services/{service}:deploy")
    public DeployResult deploy(@PathVariable @Pattern(regexp = NAME) String env,
                               @PathVariable @Pattern(regexp = NAME) String service,
                               @RequestBody @Valid DeployRequest request) {
        return envService.deploy(env, service, request.tag());
    }

    @GetMapping("/api/perf-runs")
    public List<MetricsClient.PerfRun> perfRuns() {
        return envService.perfRuns();
    }

    @GetMapping("/api/links")
    public Links links() {
        PortalProperties.Links l = properties.links();
        return new Links(l.argocd(), l.gitea(), l.grafana(), l.registry());
    }
}
