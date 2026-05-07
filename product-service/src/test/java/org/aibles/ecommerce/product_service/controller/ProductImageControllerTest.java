package org.aibles.ecommerce.product_service.controller;

import org.aibles.ecommerce.common_dto.request.AttachImageRequest;
import org.aibles.ecommerce.common_dto.request.PresignImageRequest;
import org.aibles.ecommerce.common_dto.response.PresignedUploadResponse;
import org.aibles.ecommerce.product_service.dto.response.ProductResponse;
import org.aibles.ecommerce.product_service.service.ProductImageService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.time.Instant;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(controllers = ProductImageController.class)
class ProductImageControllerTest {

    @Autowired
    private MockMvc mvc;

    @MockBean
    private ProductImageService imageService;

    @Test
    void presignReturnsSignedUrl() throws Exception {
        when(imageService.presign(eq("abc"), any(PresignImageRequest.class)))
            .thenReturn(new PresignedUploadResponse(
                "http://signed", "products/abc/x.jpg",
                Instant.parse("2026-04-27T00:00:00Z")));

        mvc.perform(post("/v1/products/abc/image/presign")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"content_type\":\"image/jpeg\",\"size_bytes\":1024}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.upload_url").value("http://signed"))
            .andExpect(jsonPath("$.data.object_key").value("products/abc/x.jpg"));
    }

    @Test
    void attachReturnsUpdatedProduct() throws Exception {
        ProductResponse resp = ProductResponse.builder()
            .id("abc")
            .imageUrl("http://localhost:9000/ecommerce-media/products/abc/x.jpg")
            .build();
        when(imageService.attach(eq("abc"), any(AttachImageRequest.class))).thenReturn(resp);

        mvc.perform(put("/v1/products/abc/image")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"object_key\":\"products/abc/x.jpg\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.data.image_url")
                .value("http://localhost:9000/ecommerce-media/products/abc/x.jpg"));
    }
}
