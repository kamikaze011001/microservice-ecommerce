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
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.Info;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.JobRequest;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.JobView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.RevertRequest;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsRequest;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.ToolView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.Links;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.TagView;
import org.aibles.ecommerce.devbox_portal.service.EnvService;
import org.aibles.ecommerce.devbox_portal.service.JobKind;
import org.aibles.ecommerce.devbox_portal.service.JobService;
import org.aibles.ecommerce.devbox_portal.service.SettingsService;
import org.aibles.ecommerce.devbox_portal.service.ToolService;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

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

    private static final String JOB_NAME = "devbox-[a-z0-9-]{1,63}";
    private static final String PERF_RUN = "[a-z0-9-]{1,80}";

    private final EnvService envService;
    private final JobService jobService;
    private final ToolService toolService;
    private final SettingsService settingsService;
    private final PortalProperties properties;

    public PortalController(EnvService envService, JobService jobService, ToolService toolService,
                            SettingsService settingsService, PortalProperties properties) {
        this.envService = envService;
        this.jobService = jobService;
        this.toolService = toolService;
        this.settingsService = settingsService;
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

    @GetMapping("/api/info")
    public Info info() {
        PortalProperties.Runner runner = properties.runner();
        return new Info(links(), runner.maxPreviews(), runner.image() != null && !runner.image().isBlank());
    }

    @PostMapping("/api/jobs")
    @ResponseStatus(HttpStatus.CREATED)
    public JobView startJob(@RequestBody @Valid JobRequest request) {
        return jobService.start(request.kind(), request.target(),
                request.params() == null ? Map.of() : request.params());
    }

    @GetMapping("/api/jobs")
    public List<JobView> jobs() {
        return jobService.jobs();
    }

    @GetMapping("/api/jobs/{name}")
    public JobView job(@PathVariable @Pattern(regexp = JOB_NAME) String name) {
        return jobService.job(name);
    }

    @GetMapping(value = "/api/jobs/{name}/log", produces = MediaType.TEXT_PLAIN_VALUE)
    public String jobLog(@PathVariable @Pattern(regexp = JOB_NAME) String name) {
        return jobService.log(name);
    }

    @GetMapping("/api/tools")
    public List<ToolView> tools() {
        return toolService.tools();
    }

    @GetMapping("/api/envs/{env}/services/{service}/settings")
    public SettingsView settings(@PathVariable @Pattern(regexp = NAME) String env,
                                 @PathVariable @Pattern(regexp = NAME) String service) {
        return settingsService.get(env, service);
    }

    @PutMapping("/api/envs/{env}/services/{service}/settings")
    public SettingsResult saveSettings(@PathVariable @Pattern(regexp = NAME) String env,
                                       @PathVariable @Pattern(regexp = NAME) String service,
                                       @RequestBody SettingsRequest request) {
        return settingsService.save(env, service, request.spring(), request.envVars(), request.baseSha());
    }

    @PostMapping("/api/envs/{env}/services/{service}/settings:revert")
    public SettingsResult revertSettings(@PathVariable @Pattern(regexp = NAME) String env,
                                         @PathVariable @Pattern(regexp = NAME) String service,
                                         @RequestBody @Valid RevertRequest request) {
        if (!request.commit().matches("[0-9a-f]{7,40}")) {
            throw new IllegalArgumentException("not a commit sha: " + request.commit());
        }
        return settingsService.revert(env, service, request.commit());
    }

    @GetMapping("/api/perf-compare")
    public MetricsClient.PerfComparison comparePerf(@RequestParam @Pattern(regexp = PERF_RUN) String a,
                                                    @RequestParam @Pattern(regexp = PERF_RUN) String b) {
        return envService.comparePerf(a, b);
    }

    /** Scenarios and the profiles each supports — the Perf page's run form. */
    @GetMapping("/api/perf-scenarios")
    public Map<String, java.util.Set<String>> perfScenarios() {
        return JobKind.perfProfiles();
    }

    /** What the Build page can build: branches pushed to the devbox code repo. */
    @GetMapping("/api/source/branches")
    public List<GiteaClient.Branch> branches() {
        return envService.branches();
    }
}
