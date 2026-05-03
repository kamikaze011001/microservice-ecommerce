package org.aibles.ecommerce.authorization_server.controller;

import com.nimbusds.jose.jwk.JWKSet;
import org.aibles.ecommerce.authorization_server.entity.User;
import org.aibles.ecommerce.authorization_server.service.UserAvatarService;
import org.aibles.ecommerce.authorization_server.util.SecurityUtil;
import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.MockedStatic;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = UserAvatarController.class,
    excludeAutoConfiguration = {
        org.springframework.boot.autoconfigure.security.servlet.SecurityAutoConfiguration.class,
        org.springframework.boot.autoconfigure.security.servlet.SecurityFilterAutoConfiguration.class
    })
@AutoConfigureMockMvc(addFilters = false)
class UserAvatarControllerTest {

    @Autowired
    private MockMvc mvc;

    @MockBean
    private UserAvatarService avatarService;

    @MockBean
    private JWKSet jwkSet;

    private MockedStatic<SecurityUtil> securityUtilMock;

    @AfterEach
    void tearDown() {
        if (securityUtilMock != null) securityUtilMock.close();
    }

    @Test
    void presignReturnsSignedUrl() throws Exception {
        securityUtilMock = mockStatic(SecurityUtil.class);
        securityUtilMock.when(SecurityUtil::getUserId).thenReturn("u1");
        when(avatarService.presign(eq("u1"), any(PresignImageRequest.class)))
            .thenReturn(new PresignedUploadResponse(
                "http://signed", "avatars/u1/x.png",
                Instant.parse("2026-04-27T00:00:00Z")));

        mvc.perform(post("/v1/users/self/avatar/presign")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"content_type\":\"image/png\",\"size_bytes\":1024}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.upload_url").value("http://signed"))
            .andExpect(jsonPath("$.data.object_key").value("avatars/u1/x.png"));
    }

    @Test
    void attachReturnsUpdatedUser() throws Exception {
        securityUtilMock = mockStatic(SecurityUtil.class);
        securityUtilMock.when(SecurityUtil::getUserId).thenReturn("u1");
        User u = new User();
        u.setId("u1");
        u.setAvatarUrl("http://localhost:9000/ecommerce-media/avatars/u1/x.png");
        when(avatarService.attach(eq("u1"), any(AttachImageRequest.class))).thenReturn(u);

        mvc.perform(put("/v1/users/self/avatar")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"object_key\":\"avatars/u1/x.png\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.avatarUrl")
                .value("http://localhost:9000/ecommerce-media/avatars/u1/x.png"));
    }
}
