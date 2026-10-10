package org.aibles.ecommerce.devbox_portal.service.impl;

import org.aibles.ecommerce.devbox_portal.client.ArgoClient;
import org.aibles.ecommerce.devbox_portal.client.GiteaClient;
import org.aibles.ecommerce.devbox_portal.client.MetricsClient;
import org.aibles.ecommerce.devbox_portal.client.RegistryClient;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.DeployResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.EnvView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.TagView;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class EnvServiceImplTest {

    private static final String ORDER_FILE = "apps:\n  order-service:\n    image:\n      tag: ac48ad8\n";
    private static final String ORDER_PATH = "envs/prod-like/services/order-service.yaml";

    private GiteaClient gitea;
    private RegistryClient registry;
    private ArgoClient argo;
    private EnvServiceImpl service;

    @BeforeEach
    void setUp() {
        gitea = mock(GiteaClient.class);
        registry = mock(RegistryClient.class);
        argo = mock(ArgoClient.class);
        service = new EnvServiceImpl(gitea, registry, argo, mock(MetricsClient.class));
        when(gitea.read(ORDER_PATH)).thenReturn(new GiteaClient.RepoFile(ORDER_PATH, ORDER_FILE, "blob-1"));
    }

    @Test
    void deployCommitsTheNewTagGuardedByTheBlobItReadAndNudgesArgo() {
        when(registry.exists("order-service", "9f8e7d6")).thenReturn(true);
        when(gitea.update(any(), anyString(), anyString(), anyString())).thenReturn("c0ffee");

        DeployResult result = service.deploy("prod-like", "order-service", "9f8e7d6");

        verify(gitea).update(eq(new GiteaClient.RepoFile(ORDER_PATH, ORDER_FILE, "blob-1")),
                eq("apps:\n  order-service:\n    image:\n      tag: 9f8e7d6\n"),
                eq("deploy order-service ac48ad8 → 9f8e7d6"), anyString());
        verify(argo).refresh("prod-like-order-service");
        assertThat(result).isEqualTo(new DeployResult("prod-like", "order-service", "ac48ad8", "9f8e7d6",
                "c0ffee", true, true));
    }

    @Test
    void sameTagCommitsNothing() {
        DeployResult result = service.deploy("prod-like", "order-service", "ac48ad8");

        assertThat(result.changed()).isFalse();
        verify(gitea, never()).update(any(), anyString(), anyString(), anyString());
        verifyNoInteractions(registry, argo);
    }

    @Test
    void aTagTheRegistryDoesNotHaveIsRefusedBeforeAnyCommit() {
        when(registry.exists("order-service", "nope")).thenReturn(false);

        assertThatThrownBy(() -> service.deploy("prod-like", "order-service", "nope"))
                .isInstanceOf(PortalException.class)
                .satisfies(e -> assertThat(((PortalException) e).status()).isEqualTo(HttpStatus.UNPROCESSABLE_ENTITY))
                .hasMessageContaining("not in the registry");
        verify(gitea, never()).update(any(), anyString(), anyString(), anyString());
    }

    @Test
    void aFailedArgoRefreshStillReportsTheCommittedDeploy() {
        when(registry.exists("order-service", "9f8e7d6")).thenReturn(true);
        when(gitea.update(any(), anyString(), anyString(), anyString())).thenReturn("c0ffee");
        doThrow(PortalException.upstream("k8s", new RuntimeException("down"))).when(argo).refresh(anyString());

        DeployResult result = service.deploy("prod-like", "order-service", "9f8e7d6");

        assertThat(result.changed()).isTrue();
        assertThat(result.refreshed()).isFalse();
        assertThat(result.commit()).isEqualTo("c0ffee");
    }

    @Test
    void anInvalidTagNeverReachesGit() {
        assertThatThrownBy(() -> service.deploy("prod-like", "order-service", "x\n    hpa: null"))
                .isInstanceOf(IllegalArgumentException.class);
        verifyNoInteractions(gitea, registry, argo);
    }

    @Test
    void envsJoinWhatGitSaysWithWhatArgoReports() {
        when(gitea.list("envs", "dir")).thenReturn(List.of("prod-like"));
        when(gitea.list("envs/prod-like/services", "file")).thenReturn(List.of("order-service.yaml", "redis.yaml", "README.md"));
        when(gitea.read("envs/prod-like/services/redis.yaml"))
                .thenReturn(new GiteaClient.RepoFile("…", "envRedis:\n  enabled: true\n", "b"));
        when(argo.applications()).thenReturn(Map.of("prod-like-order-service",
                new ArgoClient.AppStatus("Synced", "Healthy", "abc", List.of("localhost:5000/order-service:ac48ad8"))));

        List<EnvView> envs = service.envs();

        assertThat(envs).hasSize(1);
        assertThat(envs.get(0).services()).extracting("name", "desiredTag", "sync", "health")
                .containsExactly(
                        org.assertj.core.groups.Tuple.tuple("order-service", "ac48ad8", "Synced", "Healthy"),
                        // No image tag (its own Redis) and no Application yet: shown, not hidden.
                        org.assertj.core.groups.Tuple.tuple("redis", null, "Missing", "Missing"));
    }

    @Test
    void tagsListPinnedFirstAndDevLast() {
        when(gitea.list("envs", "dir")).thenReturn(List.of("prod-like"));
        when(gitea.list("envs/prod-like/services", "file")).thenReturn(List.of("order-service.yaml"));
        when(registry.tags("order-service")).thenReturn(List.of("dev", "1111111", "ac48ad8", "9f8e7d6"));

        List<TagView> tags = service.tags("order-service");

        assertThat(tags).extracting(TagView::tag).containsExactly("ac48ad8", "9f8e7d6", "1111111", "dev");
        assertThat(tags.get(0).usedBy()).containsExactly("prod-like");
    }
}
