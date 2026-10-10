package org.aibles.ecommerce.devbox_portal.configuration;

import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.KubernetesClientBuilder;
import org.aibles.ecommerce.devbox_portal.client.ArgoClient;
import org.aibles.ecommerce.devbox_portal.client.GiteaClient;
import org.aibles.ecommerce.devbox_portal.client.MetricsClient;
import org.aibles.ecommerce.devbox_portal.client.RegistryClient;
import org.aibles.ecommerce.devbox_portal.service.EnvService;
import org.aibles.ecommerce.devbox_portal.service.impl.EnvServiceImpl;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestClient;

/** Manual wiring, as in every service in this repo (no @Service on implementations). */
@Configuration
public class PortalConfiguration {

    @Bean
    public GiteaClient giteaClient(RestClient.Builder builder, PortalProperties properties) {
        PortalProperties.Gitea gitea = properties.gitea();
        return new GiteaClient(builder.clone()
                .baseUrl(gitea.url())
                .defaultHeaders(h -> h.setBasicAuth(gitea.user(), gitea.password()))
                .build(), gitea);
    }

    @Bean
    public RegistryClient registryClient(RestClient.Builder builder, PortalProperties properties) {
        return new RegistryClient(builder.clone().baseUrl(properties.registryUrl()).build());
    }

    @Bean
    public MetricsClient metricsClient(RestClient.Builder builder, PortalProperties properties) {
        return new MetricsClient(builder.clone().baseUrl(properties.metricsUrl()).build());
    }

    /** In a pod: the mounted ServiceAccount. Run locally: the kubeconfig's current context. */
    @Bean(destroyMethod = "close")
    public KubernetesClient kubernetesClient() {
        return new KubernetesClientBuilder().build();
    }

    @Bean
    public ArgoClient argoClient(KubernetesClient kubernetes, PortalProperties properties) {
        return new ArgoClient(kubernetes, properties.argoNamespace());
    }

    @Bean
    public EnvService envService(GiteaClient gitea, RegistryClient registry, ArgoClient argo, MetricsClient metrics) {
        return new EnvServiceImpl(gitea, registry, argo, metrics);
    }
}
