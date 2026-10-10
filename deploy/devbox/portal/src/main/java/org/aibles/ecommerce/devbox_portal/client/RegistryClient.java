package org.aibles.ecommerce.devbox_portal.client;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.util.ArrayList;
import java.util.List;

/** The minikube registry addon, through the Docker Registry HTTP API v2. */
public class RegistryClient {

    // Both flavours: buildx pushes OCI indexes, classic docker v2 manifests.
    // Without these Accept types the registry answers 404 for an OCI-only tag.
    private static final String MANIFEST_ACCEPT = String.join(", ",
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.docker.distribution.manifest.v2+json");

    private final RestClient http;

    public RegistryClient(RestClient http) {
        this.http = http;
    }

    public List<String> tags(String repository) {
        try {
            JsonNode res = http.get().uri("/v2/{repo}/tags/list", repository).retrieve().body(JsonNode.class);
            List<String> tags = new ArrayList<>();
            if (res != null) {
                res.path("tags").forEach(t -> tags.add(t.asText()));
            }
            return tags;
        } catch (HttpClientErrorException.NotFound e) {
            return List.of();
        } catch (RestClientException e) {
            throw PortalException.upstream("the registry", e);
        }
    }

    /** True if {@code repository:tag} can be pulled right now. */
    public boolean exists(String repository, String tag) {
        try {
            http.head().uri("/v2/{repo}/manifests/{tag}", repository, tag)
                    .header("Accept", MANIFEST_ACCEPT)
                    .retrieve().toBodilessEntity();
            return true;
        } catch (HttpClientErrorException.NotFound e) {
            return false;
        } catch (RestClientException e) {
            throw PortalException.upstream("the registry", e);
        }
    }
}
