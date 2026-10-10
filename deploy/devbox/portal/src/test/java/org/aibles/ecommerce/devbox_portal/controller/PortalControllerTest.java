package org.aibles.ecommerce.devbox_portal.controller;

import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.DeployResult;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.aibles.ecommerce.devbox_portal.service.EnvService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

// A web slice doesn't run @ConfigurationPropertiesScan — enable the record explicitly.
@WebMvcTest(PortalController.class)
@EnableConfigurationProperties(PortalProperties.class)
@TestPropertySource(properties = {
        "devbox.gitea.url=http://gitea", "devbox.gitea.user=u", "devbox.gitea.password=p",
        "devbox.gitea.owner=devbox", "devbox.gitea.env-repo=env-config", "devbox.gitea.branch=main",
        "devbox.registry-url=http://r", "devbox.metrics-url=http://m", "devbox.argo-namespace=argocd",
        "devbox.links.argocd=http://localhost:8180"})
class PortalControllerTest {

    @Autowired
    private MockMvc mvc;

    @MockBean
    private EnvService envService;

    @Test
    void deployIsAColonActionAndAnswersSnakeCase() throws Exception {
        when(envService.deploy("prod-like", "order-service", "9f8e7d6"))
                .thenReturn(new DeployResult("prod-like", "order-service", "ac48ad8", "9f8e7d6", "c0ffee", true, true));

        mvc.perform(post("/api/envs/prod-like/services/order-service:deploy")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"tag\":\"9f8e7d6\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.previous_tag").value("ac48ad8"))
                .andExpect(jsonPath("$.commit").value("c0ffee"));
    }

    @Test
    void namesThatCouldEscapeTheEnvRepoPathAreRejected() throws Exception {
        mvc.perform(post("/api/envs/Prod_Like/services/order-service:deploy")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"tag\":\"dev\"}"))
                .andExpect(status().isBadRequest());
        mvc.perform(get("/api/services/..%2Fsecrets/tags"))
                .andExpect(status().is4xxClientError());
        verifyNoInteractions(envService);
    }

    @Test
    void aBlankTagIsABadRequest() throws Exception {
        mvc.perform(post("/api/envs/prod-like/services/order-service:deploy")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"tag\":\"\"}"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void portalErrorsKeepTheirStatusAndOneSentence() throws Exception {
        when(envService.deploy(anyString(), anyString(), anyString()))
                .thenThrow(PortalException.conflict("envs/prod-like/services/order-service.yaml changed since it was read"));

        mvc.perform(post("/api/envs/prod-like/services/order-service:deploy")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"tag\":\"9f8e7d6\"}"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("envs/prod-like/services/order-service.yaml changed since it was read"));
    }

    @Test
    void linksComeFromConfiguration() throws Exception {
        mvc.perform(get("/api/links")).andExpect(status().isOk())
                .andExpect(jsonPath("$.argocd").value("http://localhost:8180"));
    }
}
