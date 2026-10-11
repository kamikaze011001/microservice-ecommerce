package org.aibles.ecommerce.devbox_portal.service.impl;

import io.fabric8.kubernetes.api.model.Secret;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.KubernetesClientException;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.ToolView;
import org.aibles.ecommerce.devbox_portal.service.ToolService;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;

/**
 * Logins for the local platform's UIs, read live from where each tool keeps
 * them (so a re-installed Argo CD's new password just shows up). Local-only
 * dev credentials on a single-user cluster — RBAC lets the portal read
 * exactly these two Secrets and nothing else (portal/k8s.yaml).
 */
@Slf4j
public class ToolServiceImpl implements ToolService {

    private final KubernetesClient kubernetes;
    private final PortalProperties properties;

    public ToolServiceImpl(KubernetesClient kubernetes, PortalProperties properties) {
        this.kubernetes = kubernetes;
        this.properties = properties;
    }

    @Override
    public List<ToolView> tools() {
        PortalProperties.Links links = properties.links();
        return List.of(
                new ToolView("argocd", "Argo CD", links.argocd(),
                        "Every env × service as an Application: sync, health, history, the live resource tree.",
                        "admin", secret("argocd", "argocd-initial-admin-secret", "password")),
                new ToolView("gitea", "Gitea", links.gitea(),
                        "The env repo (every deploy is a commit) and the code Argo CD renders.",
                        properties.gitea().user(), properties.gitea().password()),
                new ToolView("grafana", "Grafana", links.grafana(),
                        "Service metrics, JVM, Kafka lag, and the k6 perf dashboards.",
                        secret("monitoring", "grafana", "admin-user"), secret("monitoring", "grafana", "admin-password")),
                new ToolView("registry", "Registry", links.registry(),
                        "Every image version built for the devbox, with its tags.",
                        null, null));
    }

    /** One key of a Secret, or null (shown as "not available") if it can't be read. */
    private String secret(String namespace, String name, String key) {
        try {
            Secret s = kubernetes.secrets().inNamespace(namespace).withName(name).get();
            Map<String, String> data = s == null ? null : s.getData();
            if (data == null || data.get(key) == null) {
                return null;
            }
            return new String(Base64.getDecoder().decode(data.get(key)), StandardCharsets.UTF_8);
        } catch (KubernetesClientException e) {
            log.warn("cannot read tool credential. secret={}/{} status={}", namespace, name, e.getCode());
            return null;
        }
    }
}
