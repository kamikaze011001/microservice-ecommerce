package org.aibles.ecommerce.devbox_portal.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.client.ArgoClient;
import org.aibles.ecommerce.devbox_portal.client.GiteaClient;
import org.aibles.ecommerce.devbox_portal.client.MetricsClient;
import org.aibles.ecommerce.devbox_portal.client.RegistryClient;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.DeployResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.EnvView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.ServiceView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.TagView;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.aibles.ecommerce.devbox_portal.service.EnvService;
import org.aibles.ecommerce.devbox_portal.service.ImageTag;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Git is the truth, Argo CD is the observer: the desired tag is read from the
 * env repo, the sync/health from Argo CD, and a deploy is a commit — never a
 * kubectl call. Same contract as `make devbox-deploy`.
 */
@Slf4j
public class EnvServiceImpl implements EnvService {

    private static final String YAML = ".yaml";

    private final GiteaClient gitea;
    private final RegistryClient registry;
    private final ArgoClient argo;
    private final MetricsClient metrics;

    public EnvServiceImpl(GiteaClient gitea, RegistryClient registry, ArgoClient argo, MetricsClient metrics) {
        this.gitea = gitea;
        this.registry = registry;
        this.argo = argo;
        this.metrics = metrics;
    }

    @Override
    public List<EnvView> envs() {
        Map<String, ArgoClient.AppStatus> apps = argo.applications();
        List<EnvView> envs = new ArrayList<>();
        for (String env : gitea.list("envs", "dir")) {
            List<ServiceView> services = new ArrayList<>();
            for (String svc : serviceNames(env)) {
                String app = env + "-" + svc;
                String desired = ImageTag.current(gitea.read(servicePath(env, svc)).content()).orElse(null);
                ArgoClient.AppStatus status = apps.getOrDefault(app,
                        new ArgoClient.AppStatus("Missing", "Missing", null, List.of()));
                services.add(new ServiceView(svc, app, desired, status.sync(), status.health(), status.images()));
            }
            envs.add(new EnvView(env, services));
        }
        return envs;
    }

    @Override
    public DeployResult deploy(String env, String service, String tag) {
        if (!ImageTag.VALID_TAG.matcher(tag).matches()) {
            throw new IllegalArgumentException("not a valid image tag: " + tag);
        }
        GiteaClient.RepoFile file = gitea.read(servicePath(env, service));
        String previous = ImageTag.current(file.content()).orElseThrow(() ->
                PortalException.unprocessable(service + " in " + env + " has no image tag to change"));
        if (previous.equals(tag)) {
            return new DeployResult(env, service, previous, tag, null, false, false);
        }
        // Committing a tag the registry doesn't have is a guaranteed
        // ImagePullBackOff that git would record as a "deploy". Refuse first.
        if (!registry.exists(service, tag)) {
            throw PortalException.unprocessable(service + ":" + tag + " is not in the registry");
        }

        String commit = gitea.update(file, ImageTag.withTag(file.content(), tag),
                "deploy " + service + " " + previous + " → " + tag, "pinned from devbox-portal");
        log.info("version deployed via portal. env={} service={} from={} to={} commit={}",
                env, service, previous, tag, commit);

        boolean refreshed = true;
        try {
            argo.refresh(env + "-" + service);
        } catch (PortalException e) {
            // The commit is the deploy; the refresh only saves up to 60s.
            refreshed = false;
            log.warn("deploy committed but Argo CD refresh failed; it will sync on its next poll. env={} service={}",
                    env, service, e);
        }
        return new DeployResult(env, service, previous, tag, commit, true, refreshed);
    }

    @Override
    public List<GiteaClient.Commit> history(String env, int limit) {
        return gitea.commits("envs/" + env, limit);
    }

    @Override
    public List<TagView> tags(String service) {
        Map<String, List<String>> usedBy = new LinkedHashMap<>();
        for (String env : gitea.list("envs", "dir")) {
            if (!serviceNames(env).contains(service)) {
                continue;
            }
            ImageTag.current(gitea.read(servicePath(env, service)).content())
                    .ifPresent(t -> usedBy.computeIfAbsent(t, k -> new ArrayList<>()).add(env));
        }
        // Pinned tags first (what you'd roll back between), then the rest; `dev` last.
        return registry.tags(service).stream()
                .sorted(Comparator.<String, Boolean>comparing(t -> !usedBy.containsKey(t))
                        .thenComparing(t -> t.equals("dev"))
                        .thenComparing(Comparator.reverseOrder()))
                .map(t -> new TagView(t, usedBy.getOrDefault(t, List.of())))
                .toList();
    }

    @Override
    public List<MetricsClient.PerfRun> perfRuns() {
        return metrics.perfRuns();
    }

    private List<String> serviceNames(String env) {
        return gitea.list("envs/" + env + "/services", "file").stream()
                .filter(f -> f.endsWith(YAML))
                .map(f -> f.substring(0, f.length() - YAML.length()))
                .sorted()
                .toList();
    }

    private static String servicePath(String env, String service) {
        return "envs/" + env + "/services/" + service + YAML;
    }
}
