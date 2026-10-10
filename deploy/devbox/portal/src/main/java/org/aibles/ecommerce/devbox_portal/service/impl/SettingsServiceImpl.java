package org.aibles.ecommerce.devbox_portal.service.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.client.ArgoClient;
import org.aibles.ecommerce.devbox_portal.client.GiteaClient;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.SettingsView;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.aibles.ecommerce.devbox_portal.service.ServiceSettings;
import org.aibles.ecommerce.devbox_portal.service.SettingsService;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;

/**
 * Settings live in the same env-repo file as the image tag, so a change is a
 * commit like a deploy: history for free, Argo CD rolls the pods (the env /
 * SPRING_APPLICATION_JSON changes the pod template), and undo is a revert.
 */
@Slf4j
public class SettingsServiceImpl implements SettingsService {

    /** Static builds (Caddy) get no Spring properties — the chart ignores springConfig for them. */
    private static final Set<String> STATIC = Set.of("frontend");

    private final GiteaClient gitea;
    private final ArgoClient argo;

    public SettingsServiceImpl(GiteaClient gitea, ArgoClient argo) {
        this.gitea = gitea;
        this.argo = argo;
    }

    @Override
    public SettingsView get(String env, String service) {
        GiteaClient.RepoFile file = gitea.read(path(env, service));
        Map<String, Map<String, String>> s = ServiceSettings.read(file.content(), service);
        Map<String, String> inherited = STATIC.contains(service)
                ? Map.of() : ServiceSettings.inheritedSpring(gitea.read("envs/" + env + "/env.yaml").content());
        return new SettingsView(env, service, STATIC.contains(service), s.get("spring"), s.get("env"),
                inherited, file.sha(), gitea.commits(path(env, service), 15));
    }

    @Override
    public SettingsResult save(String env, String service, Map<String, String> spring, Map<String, String> envVars,
                               String baseSha) {
        Map<String, String> sp = spring == null ? Map.of() : spring;
        Map<String, String> ev = envVars == null ? Map.of() : envVars;
        if (STATIC.contains(service) && !sp.isEmpty()) {
            throw new IllegalArgumentException(service + " is a static build — it takes env vars only, no Spring properties");
        }
        ServiceSettings.validate(sp, ev);

        GiteaClient.RepoFile file = gitea.read(path(env, service));
        if (baseSha != null && !baseSha.equals(file.sha())) {
            throw PortalException.conflict(service + " in " + env + " was changed since you opened it — reload to see the change");
        }
        Map<String, Map<String, String>> before = ServiceSettings.read(file.content(), service);
        String summary = summary(before.get("spring"), sp) + summary(before.get("env"), ev);
        if (summary.isBlank()) {
            return new SettingsResult(env, service, null, false, false, "nothing changed");
        }
        return commit(env, service, file, sp, ev, "settings " + service + ": " + summary.strip(), "edited in devbox-portal");
    }

    @Override
    public SettingsResult revert(String env, String service, String commit) {
        String parent = gitea.parent(commit);
        Map<String, Map<String, String>> old;
        try {
            old = ServiceSettings.read(gitea.readAt(path(env, service), parent).content(), service);
        } catch (PortalException e) {
            if (e.status().value() != 404) {
                throw e;
            }
            old = Map.of("spring", Map.of(), "env", Map.of());   // the file didn't exist yet: no settings
        }
        GiteaClient.RepoFile file = gitea.read(path(env, service));
        Map<String, Map<String, String>> now = ServiceSettings.read(file.content(), service);
        String summary = summary(now.get("spring"), old.get("spring")) + summary(now.get("env"), old.get("env"));
        if (summary.isBlank()) {
            return new SettingsResult(env, service, null, false, false, "settings already match that point");
        }
        return commit(env, service, file, old.get("spring"), old.get("env"),
                "revert settings " + service + " to before " + commit.substring(0, Math.min(7, commit.length())),
                summary.strip() + "\n\nreverted in devbox-portal");
    }

    private SettingsResult commit(String env, String service, GiteaClient.RepoFile file, Map<String, String> spring,
                                  Map<String, String> envVars, String subject, String body) {
        String sha = gitea.update(file, ServiceSettings.withSettings(file.content(), service, spring, envVars), subject, body);
        log.info("service settings committed via portal. env={} service={} commit={}", env, service, sha);
        boolean refreshed = true;
        try {
            argo.refresh(env + "-" + service);
        } catch (PortalException e) {
            refreshed = false;
            log.warn("settings committed but Argo CD refresh failed; it will sync on its next poll. env={} service={}",
                    env, service, e);
        }
        return new SettingsResult(env, service, sha, true, refreshed, subject);
    }

    /** "+added ~changed -removed " over the union of keys. */
    static String summary(Map<String, String> before, Map<String, String> after) {
        List<String> parts = new ArrayList<>();
        for (String k : new TreeSet<>(union(before.keySet(), after.keySet()))) {
            String b = before.get(k);
            String a = after.get(k);
            if (b == null) {
                parts.add("+" + k);
            } else if (a == null) {
                parts.add("-" + k);
            } else if (!Objects.equals(a, b)) {
                parts.add("~" + k);
            }
        }
        return parts.isEmpty() ? "" : String.join(" ", parts) + " ";
    }

    private static Set<String> union(Set<String> a, Set<String> b) {
        Set<String> u = new TreeSet<>(a);
        u.addAll(b);
        return u;
    }

    private static String path(String env, String service) {
        return "envs/" + env + "/services/" + service + ".yaml";
    }
}
