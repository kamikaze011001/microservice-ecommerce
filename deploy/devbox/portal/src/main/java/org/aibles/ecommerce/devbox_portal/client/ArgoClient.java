package org.aibles.ecommerce.devbox_portal.client;

import io.fabric8.kubernetes.api.model.GenericKubernetesResource;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.KubernetesClientException;
import io.fabric8.kubernetes.client.dsl.base.ResourceDefinitionContext;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Argo CD Applications, read as the CRDs they are through the Kubernetes API
 * with the pod's ServiceAccount (RBAC in portal/k8s.yaml: get/list/patch on
 * applications in the argocd namespace). No Argo CD API token to manage.
 */
public class ArgoClient {

    /** What the portal shows per Application. {@code revision} = the env-repo commit applied. */
    public record AppStatus(String sync, String health, String revision, List<String> images) {
    }

    private static final ResourceDefinitionContext APPLICATION = new ResourceDefinitionContext.Builder()
            .withGroup("argoproj.io").withVersion("v1alpha1").withKind("Application")
            .withPlural("applications").withNamespaced(true).build();

    private final KubernetesClient kubernetes;
    private final String namespace;

    public ArgoClient(KubernetesClient kubernetes, String namespace) {
        this.kubernetes = kubernetes;
        this.namespace = namespace;
    }

    /** Every devbox Application (label devbox.env), keyed by name: {@code <env>-<service>}. */
    @SuppressWarnings("unchecked")
    public Map<String, AppStatus> applications() {
        try {
            Map<String, AppStatus> out = new HashMap<>();
            for (GenericKubernetesResource app : kubernetes.genericKubernetesResources(APPLICATION)
                    .inNamespace(namespace).withLabel("devbox.env").list().getItems()) {
                Map<String, Object> status = (Map<String, Object>) app.getAdditionalProperties().getOrDefault("status", Map.of());
                Map<String, Object> sync = (Map<String, Object>) status.getOrDefault("sync", Map.of());
                Map<String, Object> health = (Map<String, Object>) status.getOrDefault("health", Map.of());
                Map<String, Object> summary = (Map<String, Object>) status.getOrDefault("summary", Map.of());
                // Multi-source: revisions[0] = the chart repo, [1] = the env repo.
                List<String> revisions = (List<String>) sync.getOrDefault("revisions", List.of());
                out.put(app.getMetadata().getName(), new AppStatus(
                        Objects.toString(sync.get("status"), "Unknown"),
                        Objects.toString(health.get("status"), "Unknown"),
                        revisions.size() > 1 ? revisions.get(1) : null,
                        (List<String>) summary.getOrDefault("images", List.of())));
            }
            return out;
        } catch (KubernetesClientException e) {
            throw PortalException.upstream("the Kubernetes API (Argo CD Applications)", e);
        }
    }

    /** Ask Argo CD to look at git now instead of on its 60s poll — what `devbox-ship` does. */
    public void refresh(String application) {
        try {
            kubernetes.genericKubernetesResources(APPLICATION).inNamespace(namespace).withName(application)
                    .edit(app -> {
                        Map<String, String> annotations = app.getMetadata().getAnnotations();
                        if (annotations == null) {
                            annotations = new HashMap<>();
                            app.getMetadata().setAnnotations(annotations);
                        }
                        annotations.put("argocd.argoproj.io/refresh", "normal");
                        return app;
                    });
        } catch (KubernetesClientException e) {
            throw PortalException.upstream("the Kubernetes API (refresh " + application + ")", e);
        }
    }
}
